import Foundation

/// Commits and releases one binding's ownership through a single attachment path.
@MainActor
final class AutoDisposeInstanceController {
    private final class Registration {
        let handle: any _AnyHandle
        var cancelListener: (() -> Void)?

        init(handle: any _AnyHandle) { self.handle = handle }
    }

    private unowned let binding: ViewModelBinding
    private let onHandleDisposing: () -> Void
    private let onInstanceAttaching: ((any _AnyHandle, ViewModel) throws -> Void)?
    private let onInstanceAttached: ((any _AnyHandle, ViewModel) -> (() -> Void)?)?
    private let onInstanceDetached: ((any _AnyHandle, ViewModel) -> (() -> Void)?)?
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var disposed = false

    init(
        binding: ViewModelBinding,
        onHandleDisposing: @escaping () -> Void,
        onInstanceAttaching: ((any _AnyHandle, ViewModel) throws -> Void)? = nil,
        onInstanceAttached: ((any _AnyHandle, ViewModel) -> (() -> Void)?)? = nil,
        onInstanceDetached: ((any _AnyHandle, ViewModel) -> (() -> Void)?)? = nil
    ) {
        self.binding = binding
        self.onHandleDisposing = onHandleDisposing
        self.onInstanceAttaching = onInstanceAttaching
        self.onInstanceAttached = onInstanceAttached
        self.onInstanceDetached = onInstanceDetached
    }

    func getInstance<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>
    ) throws -> Value {
        try getHandle(type, factory: factory).requireInstance()
    }

    func getHandle<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>
    ) throws -> InstanceHandle<Value> {
        guard !disposed, !binding.isDisposed else {
            throw ViewModelError("Cannot resolve an instance for a disposed binding.")
        }
        let factoryWithBinding = factory.copy(
            arg: factory.arg.copy(bindingId: .some(binding.id))
        )
        return try InstanceManager.shared.getHandle(
            type,
            factory: factoryWithBinding,
            onResolve: { _ = try self.attachHandle($0) }
        )
    }

    func getInstancesByTag<Value: AnyObject>(
        _ type: Value.Type,
        tag: AnyHashable
    ) throws -> [Value] {
        guard !disposed, !binding.isDisposed else {
            throw ViewModelError("Cannot resolve instances for a disposed binding.")
        }
        let handles = try InstanceManager.shared.getHandles(byTag: tag, type: type)
        // Reject invalid dependency edges before acquiring any batch member.
        for handle in handles { try validateAttachment(handle) }
        var added: [Registration] = []
        do {
            var result: [Value] = []
            for handle in handles {
                if let registration = try attachHandle(handle) {
                    added.append(registration)
                }
                result.append(try handle.requireInstance())
            }
            return result
        } catch {
            for registration in added.reversed() { detach(registration) }
            throw error
        }
    }

    func performForAllInstances(_ action: (ViewModel) -> Void) {
        for registration in Array(registrations.values) {
            let handle = registration.handle
            guard !handle.isDisposedAny, let vm = handle.anyValue as? ViewModel else { continue }
            action(vm)
        }
    }

    func unbind<Value: AnyObject>(_ value: Value) {
        guard !disposed else { return }
        guard let registration = registrations.values.first(where: { $0.handle.anyValue === value }) else {
            return
        }
        detach(registration)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        for registration in Array(registrations.values) { detach(registration) }
    }

    private func requireLive(_ handle: any _AnyHandle) throws {
        guard !disposed, !binding.isDisposed else {
            throw ViewModelError("Cannot attach: binding was disposed during resolution.")
        }
        guard !handle.isDisposedAny else {
            throw ViewModelError("Cannot attach: instance was disposed during resolution.")
        }
    }

    private func validateAttachment(_ handle: any _AnyHandle) throws {
        try requireLive(handle)
        if registrations[ObjectIdentifier(handle)] == nil,
           let vm = handle.anyValue as? ViewModel {
            try onInstanceAttaching?(handle, vm)
        }
    }

    /// Returns only a newly installed registration, for batch rollback.
    private func attachHandle<Value: AnyObject>(
        _ handle: InstanceHandle<Value>
    ) throws -> Registration? {
        try validateAttachment(handle)
        let key = ObjectIdentifier(handle)
        if registrations[key] != nil {
            // Internal callers can remove one ledger's direct source. A normal
            // read repairs it without duplicating the existing registration.
            try handle.bindOwner(binding)
            try requireLive(handle)
            guard handle.containsDirectBinding(binding.id) else {
                throw ViewModelError("Ownership was released while binding an instance.")
            }
            return nil
        }
        let publish = (handle.value as? ViewModel).flatMap { onInstanceAttached?(handle, $0) }
        let registration = Registration(handle: handle)
        registrations[key] = registration
        registration.cancelListener = handle.addListener { [weak self, weak registration] _ in
            guard let self, let registration else { return }
            self.detach(registration)
            if !InstanceManager.shared.isResetting, !self.disposed { self.onHandleDisposing() }
        }
        do {
            // Graph adjacency and disposal tracking must exist before onBind.
            try handle.bindOwner(binding)
            if registrations[key] === registration { publish?() }
            try requireLive(handle)
            guard handle.containsDirectBinding(binding.id) else {
                throw ViewModelError("Ownership was released while binding an instance.")
            }
            return registrations[key] === registration ? registration : nil
        } catch {
            detach(registration)
            throw error
        }
    }

    private func detach(_ registration: Registration) {
        let handle = registration.handle
        let key = ObjectIdentifier(handle)
        // Old cleanup must never remove a replacement installed by reentry.
        guard registrations[key] === registration else { return }
        registrations.removeValue(forKey: key)
        registration.cancelListener?()
        registration.cancelListener = nil
        let publish = (handle.anyValue as? ViewModel).flatMap { onInstanceDetached?(handle, $0) }
        publish?()
        // Preserve Apple's propagated-root-before-dependency unbind order.
        // A callback may already have reused the direct source in a new
        // registration; only the old edge's distinct sources were ours to remove.
        if registrations[key] == nil {
            handle.unbindOwnerAny(binding, source: nil)
        }
    }
}

/// Type-erased registry handle used by one binding across multiple VM types.
@MainActor
protocol _AnyHandle: AnyObject {
    var anyValue: AnyObject? { get }
    var isDisposedAny: Bool { get }
    func bindOwnerAny(_ owner: ViewModelBinding, source: AnyObject) throws
    func unbindOwnerAny(_ owner: ViewModelBinding, source: AnyObject?)
}

extension InstanceHandle: _AnyHandle {
    var anyValue: AnyObject? { value }
    var isDisposedAny: Bool { isDisposed }
    func bindOwnerAny(_ owner: ViewModelBinding, source: AnyObject) throws {
        try bindOwner(owner, source: source)
    }
    func unbindOwnerAny(_ owner: ViewModelBinding, source: AnyObject?) {
        unbindOwner(owner, source: source)
    }
}
