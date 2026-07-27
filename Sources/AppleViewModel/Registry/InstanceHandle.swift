import Foundation

/// Reference-counted wrapper around a single managed instance (typically a `ViewModel`).
///
/// Responsibilities, mirrored from the Dart `InstanceHandle`:
/// - invoke `onCreate` once the value is stored,
/// - maintain the `bindingIds` reference-count list,
/// - support `recreate` with a replacement builder,
/// - auto-dispose when `bindingIds` reaches zero (unless `aliveForever`).
@MainActor
final class InstanceHandle<Value: AnyObject> {
    /// The wrapped instance. Set to `nil` after `onDispose`.
    private(set) var value: Value?

    /// Identity metadata captured at creation time.
    let arg: InstanceArg

    /// Builder used to rebuild the instance during `recreate()`.
    let factory: @MainActor () -> Value

    /// Monotonic index, set by the owning store. Higher means more recent and is
    /// used by `findNewlyInstance`.
    let index: Int

    private var bindingSources: [String: Set<ObjectIdentifier>] = [:]
    private var directBindingSources: [String: NSObject] = [:]

    var bindingIds: [String] { Array(bindingSources.keys) }
    var isDisposed: Bool { disposed }

    /// Action currently being processed, or the last one observed if the handle
    /// has already been disposed. `addListener` callers read this to tell
    /// `.dispose` apart from `.recreate`.
    var currentAction: InstanceAction? { action ?? (disposed ? lastAction : nil) }

    private var listeners: [UUID: (InstanceHandle<Value>) -> Void] = [:]
    private var action: InstanceAction?
    private var lastAction: InstanceAction?
    private var disposed = false

    init(
        value: Value,
        arg: InstanceArg,
        index: Int,
        factory: @escaping @MainActor () -> Value
    ) {
        self.value = value
        self.arg = arg
        self.index = index
        self.factory = factory
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

    /// Replace the underlying instance while keeping the reference list intact.
    /// All listeners observe `.recreate` in `currentAction` before the new value
    /// becomes visible.
    @discardableResult
    func recreate(builder: (@MainActor () -> Value)? = nil) throws -> Value {
        if disposed {
            throw ViewModelError("Cannot recreate \(Value.self) instance. Handle is disposed.")
        }
        guard let previous = value else {
            throw ViewModelError("Cannot recreate \(Value.self) instance. Instance is disposed.")
        }
        let activeBindings = bindingIds
        let key = arg.key!
        let recreated = try runInViewModelConstruction(
            Value.self,
            key: key,
            isImplicit: key.base is ViewModelPrivateKey,
            body: builder ?? factory
        )
        if !isActive(with: previous) {
            try abortInvalidatedRecreate(previous: previous, recreated: recreated)
        }
        callInstanceDispose(previous)
        if !isActive(with: previous) {
            try abortInvalidatedRecreate(previous: previous, recreated: recreated)
        }
        value = recreated
        notifyCreate(arg: arg)
        try requireActiveRecreatedInstance(recreated)
        for id in activeBindings {
            notifyBind(id: id)
            try requireActiveRecreatedInstance(recreated)
        }
        action = .recreate
        lastAction = .recreate
        runInViewModelUpdateTransaction(notifyListeners)
        action = nil
        return recreated
    }

    private func isActive(with expected: Value) -> Bool {
        !disposed && value === expected
    }

    private func abortInvalidatedRecreate(previous: Value, recreated: Value) throws -> Never {
        let replacementIsManaged = isActive(with: recreated)
        if !replacementIsManaged, recreated !== previous {
            callInstanceDispose(recreated)
        }
        throw ViewModelError(
            "Cannot recreate \(Value.self) because its handle was disposed or replaced "
                + "while the builder was running. The detached replacement was disposed "
                + "and was not installed."
        )
    }

    private func requireActiveRecreatedInstance(_ recreated: Value) throws {
        guard isActive(with: recreated) else {
            throw ViewModelError(
                "Cannot recreate \(Value.self) because its handle was disposed or replaced "
                    + "while the replacement lifecycle was being initialized."
            )
        }
    }

    /// Subscribe to action transitions on this handle. Returns a cancellation closure.
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
        action = .dispose
        lastAction = .dispose
        runInViewModelUpdateTransaction(notifyListeners)
        action = nil
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

/// Actions observable on an `InstanceHandle`. Listeners inspect
/// `handle.currentAction` inside their callback to distinguish the two.
enum InstanceAction {
    case dispose
    case recreate
}
