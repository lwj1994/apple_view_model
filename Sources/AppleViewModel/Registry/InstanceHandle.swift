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

    private var bindingIdList: [String] = []

    var bindingIds: [String] { bindingIdList }
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
        bindingIdList.contains(bindingId)
    }

    /// Append an additional `bindingId`. Duplicates and `nil` are ignored.
    func bind(_ id: String?) {
        guard let id, !disposed, !bindingIdList.contains(id) else { return }
        bindingIdList.append(id)
        notifyBind(id: id)
    }

    /// Remove a single reference. Auto-disposes when the list becomes empty, unless
    /// `aliveForever` is set.
    func unbind(_ id: String) {
        guard !disposed else { return }
        guard let idx = bindingIdList.firstIndex(of: id) else { return }
        bindingIdList.remove(at: idx)
        if let lifecycle = value as? InstanceLifeCycle {
            do {
                try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
            } catch {
                reportViewModelError(
                    error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
            }
        }
        if bindingIdList.isEmpty {
            recycle()
        }
    }

    /// Force every reference off and dispose. Pass `force: true` to override
    /// `aliveForever` (used by `recycle(_:)` on a shared instance).
    func unbindAll(force: Bool = false) {
        guard !disposed else { return }
        if arg.aliveForever, !force { return }
        for id in bindingIdList {
            if let lifecycle = value as? InstanceLifeCycle {
                do {
                    try runCatching { lifecycle.onUnbind(arg, bindingId: id) }
                } catch {
                    reportViewModelError(
                        error, type: .lifecycle, context: "\(type(of: lifecycle)) onUnbind error")
                }
            }
        }
        bindingIdList.removeAll()
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
        let activeBindings = bindingIdList
        let recreated = (builder ?? factory)()
        callInstanceDispose(previous)
        value = recreated
        notifyCreate(arg: arg)
        for id in activeBindings {
            notifyBind(id: id)
        }
        action = .recreate
        lastAction = .recreate
        notifyListeners()
        action = nil
        return recreated
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
        notifyListeners()
        action = nil
        onDispose()
    }

    private func onDispose() {
        guard !disposed else { return }
        disposed = true
        callInstanceDispose(value)
        value = nil
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
