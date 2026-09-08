import Foundation

/// Reference-counted wrapper around a single managed instance (typically a `ViewModel`).
///
/// Responsibilities, mirrored from the Dart `InstanceHandle`:
/// - invoke `onCreate` once the value is stored,
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

    init(
        value: Value,
        arg: InstanceArg,
        index: Int
    ) {
        self.value = value
        self.arg = arg
        self.index = index
        notifyCreate(arg: arg)
        if let initialId = arg.bindingId {
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
        if let lifecycle = value as? InstanceLifeCycle {
            do {
                try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
            } catch {
                reportViewModelError(
                    error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
            }
        }
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
        for id in ids {
            if let lifecycle = value as? InstanceLifeCycle {
                do {
                    try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
                } catch {
                    reportViewModelError(
                        error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
                }
            }
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
        runInViewModelUpdateTransaction(notifyListeners)
        onDispose()
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
