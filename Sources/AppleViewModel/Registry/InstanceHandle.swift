import Foundation

/// Reference-counted wrapper around a single managed instance (typically a `ViewModel`).
///
/// Responsibilities, mirrored from the Dart `InstanceHandle`:
/// - invoke `onCreate` during construction,
/// - maintain the `bindingIds` reference-count list,
/// - auto-dispose when `bindingIds` reaches zero (unless `aliveForever`).
@MainActor
final class InstanceHandle<Value: AnyObject> {
    /// The wrapped instance. Set to `nil` after `onDispose`.
    private(set) var value: Value?

    /// Identity metadata captured at creation time.
    let arg: InstanceArg

    /// Monotonic index, set by the owning store. Higher means more recent and is
    /// used by `findNewlyInstance`.
    let index: Int

    private var bindingSources: [String: Set<ObjectIdentifier>] = [:]
    private var directBindingSources: [String: NSObject] = [:]

    var bindingIds: [String] { Array(bindingSources.keys) }
    /// A disposing generation is already unavailable for resolution/ownership,
    /// even while its value remains accessible to internal teardown listeners.
    var isDisposed: Bool { disposing || disposed }

    private struct ListenerEntry {
        let id: UUID
        let callback: (InstanceHandle<Value>) throws -> Void
    }

    private var listeners: [ListenerEntry] = []
    private var disposing = false
    private var disposed = false
    private var pendingOwnerChange: (() -> Void)?

    init(
        value: Value,
        arg: InstanceArg,
        index: Int,
        bindOnCreate: Bool = true
    ) {
        self.value = value
        self.arg = arg
        self.index = index
        notifyCreate(arg: arg)
        if bindOnCreate, let initialId = arg.bindingId {
            bind(initialId)
        }
    }

    /// Returns the underlying instance or throws once disposal has begun.
    func requireInstance() throws -> Value {
        guard !isDisposed, let v = value else {
            throw ViewModelError("Cannot access \(Value.self) instance during or after disposal.")
        }
        return v
    }

    func contains(bindingId: String) -> Bool {
        bindingSources[bindingId] != nil
    }

    /// A root can also appear through a parent; fast resolution requires its
    /// own direct path, not merely membership in the visible owner list.
    func containsDirectBinding(_ id: String) -> Bool {
        directBindingSources[id] != nil
    }

    /// Add the direct ownership source for a binding id.
    func bind(_ id: String?) {
        guard let id, !isDisposed else { return }
        let source = directBindingSources[id] ?? NSObject()
        directBindingSources[id] = source
        bindFrom(id, source: source)
    }

    /// Add one identity-tracked ownership path for a visible binding id.
    func bindFrom(_ id: String?, source: AnyObject) {
        guard let id, !isDisposed else { return }
        var sources = bindingSources[id] ?? []
        guard sources.insert(ObjectIdentifier(source)).inserted else { return }
        bindingSources[id] = sources
        if sources.count == 1 { notifyBind(id: id) }
    }

    /// Single write path for managed ownership. Commit both ledgers before
    /// lifecycle or owner callbacks can resolve/unbind the instance again.
    func bindOwner(_ owner: ViewModelBinding, source: AnyObject? = nil) throws {
        guard !isDisposed, !owner.isDisposed else {
            throw ViewModelError("Cannot bind a disposed owner or instance.")
        }
        let token: AnyObject
        if let source {
            token = source
        } else {
            let direct = directBindingSources[owner.id] ?? NSObject()
            directBindingSources[owner.id] = direct
            token = direct
        }
        var sources = bindingSources[owner.id] ?? []
        let inserted = sources.insert(ObjectIdentifier(token)).inserted
        bindingSources[owner.id] = sources
        let publish = (value as? ViewModel)?.refHandler.commitAddRef(owner, source: source)
        if inserted, sources.count == 1 { notifyBind(id: owner.id) }
        publish?()
    }

    /// Release only this source. During forced disposal the handle ledger is
    /// already empty, but controllers must still finish detaching their refs.
    func unbindOwner(_ owner: ViewModelBinding, source: AnyObject? = nil) {
        guard !disposed else { return }
        let token: AnyObject? = source ?? directBindingSources.removeValue(forKey: owner.id)
        var sources = bindingSources[owner.id] ?? []
        let removed = token.map { sources.remove(ObjectIdentifier($0)) != nil } ?? false
        let last = removed && sources.isEmpty
        if last {
            bindingSources.removeValue(forKey: owner.id)
        } else if removed {
            bindingSources[owner.id] = sources
        }
        let publish = (value as? ViewModel)?.refHandler.commitRemoveRef(owner, source: source)
        publish?()
        publishPendingOwnerChange()
        if last, !disposed { notifyUnbind(id: owner.id) }
        // onUnbind may have acquired a replacement source.
        if removed, bindingSources.isEmpty { recycle() }
    }

    /// Remove a single reference. Auto-disposes when the list becomes empty, unless
    /// `aliveForever` is set.
    func unbind(_ id: String) {
        guard !isDisposed,
              let source = directBindingSources.removeValue(forKey: id) else { return }
        unbindFrom(id, source: source)
    }

    /// Remove one ownership path. Lifecycle unbind occurs after the last path leaves.
    func unbindFrom(_ id: String, source: AnyObject) {
        guard !isDisposed, var sources = bindingSources[id] else { return }
        guard sources.remove(ObjectIdentifier(source)) != nil else { return }
        if !sources.isEmpty {
            bindingSources[id] = sources
            return
        }
        bindingSources.removeValue(forKey: id)
        notifyUnbind(id: id)
        // Ordinary unbind callbacks may acquire a new owner. Only begin
        // disposal if ownership is still empty when the callback returns.
        if bindingSources.isEmpty {
            recycle()
        }
    }

    /// Force every reference off and dispose. Pass `force: true` to override
    /// `aliveForever` (used by `recycle(_:)` on a shared instance).
    func unbindAll(force: Bool = false) {
        guard !isDisposed else { return }
        if arg.aliveForever, !force { return }
        // Commit to disposal before user callbacks: onUnbind may synchronously
        // recycle this same generation or attempt to attach another owner.
        disposing = true
        let ids = Array(bindingSources.keys)
        bindingSources.removeAll()
        directBindingSources.removeAll()
        pendingOwnerChange = (value as? ViewModel)?.refHandler.commitClearRefs()
        for id in ids {
            notifyUnbind(id: id)
        }
        finishDisposal()
    }

    /// Subscribe to this handle's disposal notification. Returns a cancellation closure.
    func addListener(
        _ listener: @escaping (InstanceHandle<Value>) throws -> Void
    ) -> () -> Void {
        guard !isDisposed else { return {} }
        let id = UUID()
        listeners.append(ListenerEntry(id: id, callback: listener))
        return { [weak self] in
            self?.listeners.removeAll { $0.id == id }
        }
    }

    // MARK: - Internals

    private func recycle(force: Bool = false) {
        guard !isDisposed else { return }
        if arg.aliveForever, !force { return }
        disposing = true
        finishDisposal()
    }

    /// Keep the value alive until listeners have removed registry/owner paths,
    /// but reject recursive disposal and resolution throughout that fan-out.
    private func finishDisposal() {
        runInViewModelUpdateTransaction {
            // Store eviction runs first. Propagated unbind callbacks can then
            // resolve a replacement through the normal cache-miss path.
            notifyListeners()
            publishPendingOwnerChange()
        }
        onDispose()
    }

    private func publishPendingOwnerChange() {
        let publish = pendingOwnerChange
        pendingOwnerChange = nil
        publish?()
    }

    private func onDispose() {
        guard !disposed else { return }
        disposed = true
        callInstanceDispose(value)
        value = nil
        bindingSources.removeAll()
        directBindingSources.removeAll()
        listeners.removeAll()
        disposing = false
    }

    private func notifyCreate(arg: InstanceArg) {
        guard let lifecycle = value as? InstanceLifeCycle else { return }
        do {
            try runCatching { lifecycle.onCreate(arg) }
        } catch {
            reportViewModelError(
                error, type: .lifecycle, context: "\(type(of: lifecycle)) onCreate error")
        }
    }

    private func notifyBind(id: String) {
        guard let lifecycle = value as? InstanceLifeCycle else { return }
        do {
            try runCatching { lifecycle.onBind(arg, bindingId: id) }
        } catch {
            reportViewModelError(
                error, type: .lifecycle, context: "\(type(of: lifecycle)) onBind error")
        }
    }

    private func notifyUnbind(id: String) {
        guard let lifecycle = value as? InstanceLifeCycle else { return }
        do {
            try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
        } catch {
            reportViewModelError(
                error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
        }
    }

    private func callInstanceDispose(_ target: Value?) {
        guard let lifecycle = target as? InstanceLifeCycle else { return }
        do {
            try runCatching { lifecycle.onDispose(arg) }
        } catch {
            reportViewModelError(
                error, type: .dispose, context: "\(type(of: lifecycle)) onDispose error")
        }
    }

    private func notifyListeners() {
        let snapshot = listeners
        for entry in snapshot {
            guard listeners.contains(where: { $0.id == entry.id }) else { continue }
            do {
                try entry.callback(self)
            } catch {
                reportViewModelError(
                    error,
                    type: .listener,
                    context: "InstanceHandle listener error"
                )
            }
        }
    }

    /// Wrap a non-throwing block inside `try`/`catch` so future throwing APIs
    /// can surface via a uniform code path without touching every call site.
    private func runCatching(_ block: () throws -> Void) throws {
        try block()
    }
}
