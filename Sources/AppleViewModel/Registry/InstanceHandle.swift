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
    var isDisposed: Bool { disposed }

    private var listeners: [UUID: (InstanceHandle<Value>) -> Void] = [:]
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

    /// Returns the underlying instance or throws if it has already been disposed.
    func requireInstance() throws -> Value {
        guard let v = value else {
            throw ViewModelError("Cannot access \(Value.self) instance after disposal.")
        }
        return v
    }

    func contains(bindingId: String) -> Bool {
        bindingSources[bindingId] != nil
    }

    /// Add the direct ownership source for a binding id.
    func bind(_ id: String?) {
        guard let id, !disposed else { return }
        let source = directBindingSources[id] ?? NSObject()
        directBindingSources[id] = source
        bindFrom(id, source: source)
    }

    /// Add one identity-tracked ownership path for a visible binding id.
    func bindFrom(_ id: String?, source: AnyObject) {
        guard let id, !disposed else { return }
        var sources = bindingSources[id] ?? []
        guard sources.insert(ObjectIdentifier(source)).inserted else { return }
        bindingSources[id] = sources
        if sources.count == 1 { notifyBind(id: id) }
    }

    /// Remove a single reference. Auto-disposes when the list becomes empty, unless
    /// `aliveForever` is set.
    func unbind(_ id: String) {
        guard let source = directBindingSources.removeValue(forKey: id) else { return }
        unbindFrom(id, source: source)
    }

    /// Remove one ownership path. Lifecycle unbind occurs after the last path leaves.
    func unbindFrom(_ id: String, source: AnyObject) {
        guard !disposed, var sources = bindingSources[id] else { return }
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
        if bindingSources.isEmpty {
            recycle()
        }
    }

    /// Force every reference off and dispose. Pass `force: true` to override
    /// `aliveForever` (used by `recycle(_:)` on a shared instance).
    func unbindAll(force: Bool = false) {
        guard !disposed else { return }
        if arg.aliveForever, !force { return }
        for id in Array(bindingSources.keys) {
            if let lifecycle = value as? InstanceLifeCycle {
                do {
                    try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
                } catch {
                    reportViewModelError(
                        error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
                }
            }
        }
        bindingSources.removeAll()
        directBindingSources.removeAll()
        recycle(force: force)
    }

    /// Subscribe to this handle's disposal notification. Returns a cancellation closure.
    func addListener(_ listener: @escaping (InstanceHandle<Value>) -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            self?.listeners.removeValue(forKey: id)
        }
    }

    // MARK: - Internals

    private func recycle(force: Bool = false) {
        if arg.aliveForever, !force { return }
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
        let snapshot = Array(listeners.values)
        for listener in snapshot {
            listener(self)
        }
    }

    /// Wrap a non-throwing block inside `try`/`catch` so future throwing APIs
    /// can surface via a uniform code path without touching every call site.
    private func runCatching(_ block: () throws -> Void) throws {
        try block()
    }
}
