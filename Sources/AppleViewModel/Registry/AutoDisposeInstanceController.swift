import Foundation

/// Tracks every registry handle touched by one binding and mirrors handle
/// disposal back into the binding's source-aware hooks.
@MainActor
final class AutoDisposeInstanceController {
    private unowned let binding: ViewModelBinding
    private let onHandleDisposing: () -> Void
    private let onInstanceAttached: ((any _AnyHandle, ViewModel) throws -> Void)?
    private let onInstanceDetached: ((any _AnyHandle, ViewModel) -> Void)?

    private var trackedHandles: [ObjectIdentifier: any _AnyHandle] = [:]
    private var listenerDisposers: [ObjectIdentifier: () -> Void] = [:]
    private var disposed = false

    init(
        binding: ViewModelBinding,
        onHandleDisposing: @escaping () -> Void,
        onInstanceAttached: ((any _AnyHandle, ViewModel) throws -> Void)? = nil,
        onInstanceDetached: ((any _AnyHandle, ViewModel) -> Void)? = nil
    ) {
        self.binding = binding
        self.onHandleDisposing = onHandleDisposing
        self.onInstanceAttached = onInstanceAttached
        self.onInstanceDetached = onInstanceDetached
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
        let resolution = try InstanceManager.shared.resolveHandle(
            type,
            factory: factoryWithBinding
        )
        let handle = resolution.handle
        let viewModel = handle.value as? ViewModel
        if let viewModel {
            viewModel.refHandler.addRef(binding)
        }
        do {
            try attachHandleListener(handle)
        } catch {
            rollbackCurrentAttachment(
                handle,
                viewModel: viewModel,
                forceNewGeneration: resolution.wasCreated
            )
            throw error
        }
        return try handle.requireInstance()
    }

    func getInstancesByTag<Value: AnyObject>(
        _ type: Value.Type,
        tag: AnyHashable
    ) throws -> [Value] {
        guard !disposed else {
            throw ViewModelError(
                "AutoDisposeInstanceController.getInstancesByTag() called after dispose."
            )
        }
        let handles = try InstanceManager.shared.getHandles(byTag: tag, type: type)
        var result: [Value] = []
        for handle in handles {
            handle.bind(binding.id)
            let viewModel = handle.value as? ViewModel
            if let viewModel {
                viewModel.refHandler.addRef(binding)
            }
            do {
                try attachHandleListener(handle)
            } catch {
                rollbackCurrentAttachment(
                    handle,
                    viewModel: viewModel,
                    forceNewGeneration: false
                )
                throw error
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
        detachViewModelRef(handle: handle)
        listenerDisposers.removeValue(forKey: key)?()
        trackedHandles.removeValue(forKey: key)
        handle.unbindAny(bindingId: binding.id)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        for (key, handle) in Array(trackedHandles) {
            detachViewModelRef(handle: handle)
            listenerDisposers.removeValue(forKey: key)?()
            if !handle.isDisposedAny {
                handle.unbindAny(bindingId: binding.id)
            }
        }
        trackedHandles.removeAll()
        listenerDisposers.removeAll()
    }

    private func attachHandleListener<Value: AnyObject>(
        _ handle: InstanceHandle<Value>
    ) throws {
        guard !disposed else {
            throw ViewModelError(
                "Cannot attach \(Value.self): binding was disposed during resolution."
            )
        }
        guard !handle.isDisposed else {
            throw ViewModelError(
                "Cannot attach \(Value.self): instance was disposed during resolution."
            )
        }
        let key = ObjectIdentifier(handle)
        guard listenerDisposers[key] == nil else { return }

        if let vm = handle.value as? ViewModel {
            try onInstanceAttached?(handle, vm)
        }
        guard !disposed else {
            throw ViewModelError(
                "Cannot attach \(Value.self): binding was disposed during resolution."
            )
        }
        guard !handle.isDisposed else {
            throw ViewModelError(
                "Cannot attach \(Value.self): instance was disposed during resolution."
            )
        }
        trackedHandles[key] = handle
        listenerDisposers[key] = handle.addListener { [weak self] current in
            guard let self else { return }
            self.detachViewModelRef(handle: current)
            self.listenerDisposers.removeValue(forKey: key)?()
            self.trackedHandles.removeValue(forKey: key)
            if !InstanceManager.shared.isResetting { self.onHandleDisposing() }
        }
    }

    /// Undo only the direct ownership path introduced by the current resolve.
    /// This covers dependency-cycle rejection and lifecycle reentrancy where a
    /// ViewModel disposes its resolving binding from `onCreate` / `onBind`
    /// before the controller has committed the handle to `trackedHandles`.
    private func rollbackCurrentAttachment<Value: AnyObject>(
        _ handle: InstanceHandle<Value>,
        viewModel: ViewModel?,
        forceNewGeneration: Bool
    ) {
        if let viewModel, !viewModel.isDisposed {
            viewModel.refHandler.removeRef(binding)
        }
        if !handle.isDisposed {
            handle.unbind(binding.id)
        }
        if forceNewGeneration, !handle.isDisposed {
            handle.unbindAll(force: true)
        }
    }

    private func detachViewModelRef(handle: any _AnyHandle) {
        guard let vm = handle.anyValue as? ViewModel else { return }
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
