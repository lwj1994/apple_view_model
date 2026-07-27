import Foundation

/// Tracks every registry handle touched by one binding and mirrors handle
/// replacement/disposal back into the binding's source-aware hooks.
@MainActor
final class AutoDisposeInstanceController {
    private unowned let binding: ViewModelBinding
    private let onRecreate: () -> Void
    private let onInstanceAttached: ((any _AnyHandle, ViewModel) -> Void)?
    private let onInstanceDetached: ((any _AnyHandle, ViewModel) -> Void)?
    private let onInstanceRecreated: ((any _AnyHandle, ViewModel, ViewModel) -> Void)?

    private var trackedHandles: [ObjectIdentifier: any _AnyHandle] = [:]
    private var listenerDisposers: [ObjectIdentifier: () -> Void] = [:]
    private var trackedViewModels: [ObjectIdentifier: ViewModel] = [:]
    private var disposed = false

    init(
        binding: ViewModelBinding,
        onRecreate: @escaping () -> Void,
        onInstanceAttached: ((any _AnyHandle, ViewModel) -> Void)? = nil,
        onInstanceDetached: ((any _AnyHandle, ViewModel) -> Void)? = nil,
        onInstanceRecreated: ((any _AnyHandle, ViewModel, ViewModel) -> Void)? = nil
    ) {
        self.binding = binding
        self.onRecreate = onRecreate
        self.onInstanceAttached = onInstanceAttached
        self.onInstanceDetached = onInstanceDetached
        self.onInstanceRecreated = onInstanceRecreated
    }

    func getInstance<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>
    ) throws -> Value {
        guard !disposed else {
            throw ViewModelError("AutoDisposeInstanceController.getInstance() called after dispose.")
        }
        let factoryWithBinding = factory.copy(
            arg: factory.arg.copy(bindingId: .some(binding.id))
        )
        let handle = try InstanceManager.shared.getHandle(type, factory: factoryWithBinding)
        if let vm = handle.value as? ViewModel {
            vm.refHandler.addRef(binding)
        }
        attachRecreateListener(handle)
        return try handle.requireInstance()
    }

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
                vm.refHandler.addRef(binding)
            }
            if observeRecreate {
                attachRecreateListener(handle)
            } else {
                trackedHandles[ObjectIdentifier(handle)] = handle
            }
            if let value = handle.value { result.append(value) }
        }
        return result
    }

    func performForAllInstances(_ action: (ViewModel) -> Void) {
        for handle in trackedHandles.values {
            guard !handle.isDisposedAny, let vm = handle.anyValue as? ViewModel else { continue }
            action(vm)
        }
    }

    func unbind<Value: AnyObject>(_ value: Value) {
        guard let (key, handle) = trackedHandles.first(where: { $0.value.anyValue === value }) else {
            return
        }
        detachViewModelRef(key: key, handle: handle)
        listenerDisposers.removeValue(forKey: key)?()
        trackedHandles.removeValue(forKey: key)
        trackedViewModels.removeValue(forKey: key)
        handle.unbindAny(bindingId: binding.id)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        for (key, handle) in Array(trackedHandles) {
            detachViewModelRef(key: key, handle: handle)
            listenerDisposers.removeValue(forKey: key)?()
            if !handle.isDisposedAny {
                handle.unbindAny(bindingId: binding.id)
            }
        }
        trackedHandles.removeAll()
        listenerDisposers.removeAll()
        trackedViewModels.removeAll()
    }

    private func attachRecreateListener<Value: AnyObject>(_ handle: InstanceHandle<Value>) {
        guard !disposed else { return }
        let key = ObjectIdentifier(handle)
        guard listenerDisposers[key] == nil else { return }

        if let vm = handle.value as? ViewModel {
            onInstanceAttached?(handle, vm)
            trackedViewModels[key] = vm
        }
        trackedHandles[key] = handle
        listenerDisposers[key] = handle.addListener { [weak self, weak handle] current in
            guard let self, let handle else { return }
            switch current.currentAction {
            case .dispose:
                self.detachViewModelRef(key: key, handle: handle)
                self.listenerDisposers.removeValue(forKey: key)?()
                self.trackedHandles.removeValue(forKey: key)
                self.trackedViewModels.removeValue(forKey: key)
                if !InstanceManager.shared.isResetting { self.onRecreate() }
            case .recreate:
                let previous = self.trackedViewModels[key]
                if let replacement = handle.value as? ViewModel {
                    replacement.refHandler.addRef(self.binding)
                    self.trackedViewModels[key] = replacement
                    if let previous, previous !== replacement {
                        self.onInstanceRecreated?(handle, previous, replacement)
                    }
                }
                if !InstanceManager.shared.isResetting { self.onRecreate() }
            case .none:
                break
            }
        }
    }

    private func detachViewModelRef(key: ObjectIdentifier, handle: any _AnyHandle) {
        guard let vm = trackedViewModels[key] ?? handle.anyValue as? ViewModel else { return }
        if !vm.isDisposed { vm.refHandler.removeRef(binding) }
        onInstanceDetached?(handle, vm)
    }
}

/// Type-erased registry handle used by one binding across multiple VM types.
@MainActor
protocol _AnyHandle: AnyObject {
    var anyValue: AnyObject? { get }
    var isDisposedAny: Bool { get }
    func bindAnyFrom(bindingId: String, source: AnyObject)
    func unbindAny(bindingId: String)
    func unbindAnyFrom(bindingId: String, source: AnyObject)
}

extension InstanceHandle: _AnyHandle {
    var anyValue: AnyObject? { value }
    var isDisposedAny: Bool { isDisposed }
    func bindAnyFrom(bindingId: String, source: AnyObject) {
        bindFrom(bindingId, source: source)
    }
    func unbindAny(bindingId: String) { unbind(bindingId) }
    func unbindAnyFrom(bindingId: String, source: AnyObject) {
        unbindFrom(bindingId, source: source)
    }
}
