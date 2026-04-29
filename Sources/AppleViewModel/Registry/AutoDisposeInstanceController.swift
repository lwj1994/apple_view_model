import Foundation

/// Tracks every handle that a `ViewModelBinding` has touched and handles the
/// reference-count bookkeeping on its behalf.
///
/// Equivalent to the Dart `AutoDisposeInstanceController`. Responsibilities:
/// - tag each handle with the owning binding's id,
/// - observe `.recreate` actions so the binding can re-attach its dependency
///   reference and then call `onUpdate` to refresh the host,
/// - on binding dispose, fan out `unbind` to every tracked handle so their
///   reference counts drop (and dispose if it was the last owner).
@MainActor
final class AutoDisposeInstanceController {
    private unowned let binding: ViewModelBinding
    private let onRecreate: () -> Void

    /// Every handle currently observed. Keyed by `ObjectIdentifier` so a mix of
    /// generic instantiations can coexist in a single dictionary.
    private var trackedHandles: [ObjectIdentifier: AnyObject] = [:]

    /// Per-handle teardown closure for the `.recreate` listener.
    private var listenerDisposers: [ObjectIdentifier: () -> Void] = [:]
    private var disposed = false

    init(binding: ViewModelBinding, onRecreate: @escaping () -> Void) {
        self.binding = binding
        self.onRecreate = onRecreate
    }

    /// Resolve or create the handle, stamp the binding's id onto it, and begin
    /// tracking recreate actions. Returns the contained instance.
    func getInstance<Value: AnyObject>(_ type: Value.Type, factory: InstanceFactory<Value>) throws -> Value {
        guard !disposed else {
            throw ViewModelError("AutoDisposeInstanceController.getInstance() called after dispose.")
        }
        let factoryWithBinding = factory.copy(
            arg: factory.arg.copy(bindingId: .some(binding.id))
        )
        let handle = try InstanceManager.shared.getHandle(type, factory: factoryWithBinding)
        if let vm = handle.value as? ViewModel {
            withInternal { vm.refHandler.addRef(binding) }
        }
        attachRecreateListener(handle)
        return try handle.requireInstance()
    }

    /// Batch lookup by tag. Each matched handle is bound and tracked; when
    /// `observeRecreate` is true we also install a recreate observer.
    func getInstancesByTag<Value: AnyObject>(
        _ type: Value.Type,
        tag: AnyHashable,
        observeRecreate: Bool
    ) -> [Value] {
        let handles = InstanceManager.shared.getHandles(byTag: tag, type: type)
        var result: [Value] = []
        for handle in handles {
            handle.bind(binding.id)
            if let vm = handle.value as? ViewModel {
                withInternal { vm.refHandler.addRef(binding) }
            }
            if observeRecreate {
                attachRecreateListener(handle)
            } else {
                // Even without a recreate listener we keep the handle referenced
                // so `dispose()` walks it and emits `unbind`.
                let key = ObjectIdentifier(handle)
                if trackedHandles[key] == nil {
                    trackedHandles[key] = handle
                }
            }
            if let v = handle.value {
                result.append(v)
            }
        }
        return result
    }

    /// Invoke `action` for each tracked `ViewModel`, skipping those already disposed.
    func performForAllInstances(_ action: (ViewModel) -> Void) {
        for anyHandle in trackedHandles.values {
            guard
                let handle = anyHandle as? _AnyHandle,
                !handle.isDisposedAny,
                let vm = handle.anyValue as? ViewModel
            else { continue }
            action(vm)
        }
    }

    /// Remove the specified instance from tracking and force-dispose its handle.
    /// Used by `ViewModelBinding.recycle(_:)`.
    func recycle<Value: AnyObject>(_ value: Value) {
        for (key, anyHandle) in trackedHandles {
            guard let handle = anyHandle as? InstanceHandle<Value>, handle.value === value else { continue }
            if let disposer = listenerDisposers.removeValue(forKey: key) {
                disposer()
            }
            handle.unbindAll(force: true)
            trackedHandles.removeValue(forKey: key)
            return
        }
    }

    /// Drop only this binding's reference to `value`. Triggers dispose if that
    /// was the last reference and the instance is not `aliveForever`.
    func unbind<Value: AnyObject>(_ value: Value) {
        for anyHandle in trackedHandles.values {
            guard let handle = anyHandle as? InstanceHandle<Value>, handle.value === value else { continue }
            handle.unbind(binding.id)
            break
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        for disposer in listenerDisposers.values { disposer() }
        listenerDisposers.removeAll()

        for anyHandle in trackedHandles.values {
            guard let handle = anyHandle as? _AnyHandle else { continue }
            if handle.isDisposedAny { continue }
            if let vm = handle.anyValue as? ViewModel {
                withInternal { vm.refHandler.removeRef(binding) }
            }
            handle.unbindAny(bindingId: binding.id)
        }
        trackedHandles.removeAll()
    }

    // MARK: - Internals

    private func attachRecreateListener<Value: AnyObject>(_ handle: InstanceHandle<Value>) {
        let key = ObjectIdentifier(handle)
        trackedHandles[key] = handle
        if listenerDisposers[key] != nil { return }

        let disposer = handle.addListener { [weak self, weak handle] current in
            guard let self, let handle else { return }
            switch current.currentAction {
            case .recreate:
                if !handle.isDisposed, let vm = handle.value as? ViewModel {
                    self.withInternal { vm.refHandler.addRef(self.binding) }
                }
                self.onRecreate()
            case .dispose, .none:
                break
            }
        }
        listenerDisposers[key] = disposer
    }

    private func withInternal(_ body: () -> Void) {
        body()
    }
}

/// Type-erased handle interface so `trackedHandles` can mix different `Value`
/// instantiations.
@MainActor
protocol _AnyHandle: AnyObject {
    var anyValue: AnyObject? { get }
    var isDisposedAny: Bool { get }
    func unbindAny(bindingId: String)
}

extension InstanceHandle: _AnyHandle {
    var anyValue: AnyObject? { value }
    var isDisposedAny: Bool { isDisposed }
    func unbindAny(bindingId: String) { unbind(bindingId) }
}
