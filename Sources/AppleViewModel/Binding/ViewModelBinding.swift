import Foundation

/// Host that owns, shares, and tears down `ViewModel` instances.
///
/// Equivalent to the Dart `mixin class ViewModelBinding`. Two use patterns:
///
/// 1. **Plain Swift classes** — instantiate `ViewModelBinding()` directly, call
///    `watch` / `read` / `listen`, and invoke `dispose()` when done.
/// 2. **UI hosts** — SwiftUI and UIKit layers use the `HostedViewModelBinding`
///    subclass, which forwards change notifications through an injectable
///    `refresh` closure.
///
/// ViewModels acquired from a binding have their reference counts incremented;
/// when the binding is disposed, the counts are decremented and any ViewModel
/// whose count reaches zero (and is not `aliveForever`) is disposed
/// automatically.
@MainActor
open class ViewModelBinding {

    // MARK: - Construction-time dependency context

    /// Stack of bindings currently building a ViewModel. The top of the stack is
    /// the binding running `factory.build()` right now; once that build returns,
    /// the binding is popped.
    ///
    /// Replaces the previous `@TaskLocal current`: the build chain is fully
    /// synchronous and `@MainActor`-isolated, so a plain stack gives us the
    /// "current builder" semantics without TaskLocal's surprising boundaries
    /// (`Task.detached` not inheriting it, two unrelated Tasks each seeing
    /// their own view, etc.).
    private static var buildingStack: [ViewModelBinding] = []

    /// Top of the construction stack, or `nil` when no VM is being built.
    /// Read by `ViewModelBindingHandler` as a fallback while a VM's `init()`
    /// runs (before `refHandler.addRef(...)` has populated the handler).
    @_spi(Internal) public static var currentBuilding: ViewModelBinding? {
        buildingStack.last
    }

    /// Run `body` with `binding` pushed as the current builder. Pops on exit
    /// (including via thrown errors).
    @_spi(Internal) public static func withBuilding<R>(
        _ binding: ViewModelBinding,
        _ body: () throws -> R
    ) rethrows -> R {
        buildingStack.append(binding)
        defer { buildingStack.removeLast() }
        return try body()
    }

    // MARK: - Identity and state

    /// Globally unique id used to key reference counts on `InstanceHandle`.
    public let id: String = "Binding#\(UUID().uuidString)"

    var isDependencyBinding: Bool { false }

    public private(set) var isDisposed: Bool = false

    public var isPaused: Bool { pauseController.isPaused }

    /// Registered VMs for which we are listening to `notifyListeners`.
    /// Used to de-duplicate repeated `addListener` calls on the same VM.
    private var watchedViewModels: [ObjectIdentifier: () -> Void] = [:]

    /// Per-subscription teardown closures (from `listen`, `listenState`, etc.).
    private var disposes: [() -> Void] = []
    private var subscriptions: [BindingSubscription] = []

    /// Set to true when a notification arrives while we are paused. Drained on resume.
    private var hasMissedUpdates: Bool = false

    private var instanceAttachedHook: ((any _AnyHandle, ViewModel) -> Void)?
    private var instanceDetachedHook: ((any _AnyHandle, ViewModel) -> Void)?
    private var instanceRecreatedHook: ((any _AnyHandle, ViewModel, ViewModel) -> Void)?
    private var viewModelUpdateHook: ((ViewModel) -> Void)?
    private let defaultViewModelKey = AnyHashable(ViewModelPrivateKey())

    private lazy var instanceController: AutoDisposeInstanceController = {
        AutoDisposeInstanceController(
            binding: self,
            onRecreate: { [weak self] in self?.handleInstanceChange() },
            onInstanceAttached: { [weak self] handle, viewModel in
                self?.handleInstanceAttached(handle, viewModel: viewModel)
            },
            onInstanceDetached: { [weak self] handle, viewModel in
                self?.handleInstanceDetached(handle, viewModel: viewModel)
            },
            onInstanceRecreated: { [weak self] handle, previous, current in
                self?.handleInstanceRecreated(handle, previous: previous, current: current)
            }
        )
    }()

    private lazy var _pauseController: PauseAwareController = makePauseController()

    public var pauseController: PauseAwareController { _pauseController }

    public init() {}

    static func aliveForeverKeyValidationError(
        configuredKey: AnyHashable?,
        aliveForever: Bool
    ) -> String? {
        guard aliveForever, configuredKey == nil else { return nil }
        return "An aliveForever ViewModel must use an explicit key. "
            + "aliveForever retains the instance after ownership reaches zero, so "
            + "an unkeyed binding-private identity would not be globally reachable."
    }

    private func handleInstanceChange() {
        if markViewModelBindingUpdated(self) { onUpdate() }
    }

    private func handleInstanceAttached(_ handle: any _AnyHandle, viewModel: ViewModel) {
        instanceAttachedHook?(handle, viewModel)
    }

    private func handleInstanceDetached(_ handle: any _AnyHandle, viewModel: ViewModel) {
        watchedViewModels.removeValue(forKey: ObjectIdentifier(viewModel))?()
        let attached = subscriptions.filter { $0.isAttached(to: viewModel) }
        for subscription in attached {
            subscription.dispose()
            subscriptions.removeAll { $0 === subscription }
        }
        instanceDetachedHook?(handle, viewModel)
    }

    private func handleInstanceRecreated(
        _ handle: any _AnyHandle,
        previous: ViewModel,
        current: ViewModel
    ) {
        if let disposer = watchedViewModels.removeValue(forKey: ObjectIdentifier(previous)) {
            disposer()
            addListener(current)
        }
        for subscription in subscriptions where subscription.isAttached(to: previous) {
            subscription.move(to: current)
        }
        instanceRecreatedHook?(handle, previous, current)
    }

    /// Override to install default pause providers for a subclass.
    open func makePauseController() -> PauseAwareController {
        PauseAwareController(
            onPause: { [weak self] in self?.onPause() },
            onResume: { [weak self] in self?.onResume() }
        )
    }

    // MARK: - Hooks

    /// Called when any watched ViewModel triggers `notifyListeners`.
    /// Subclasses (SwiftUI host, UIKit view controller, etc.) override this to refresh UI.
    open func onUpdate() {}

    open func onPause() {}

    open func onResume() {
        if hasMissedUpdates {
            hasMissedUpdates = false
            onUpdate()
            viewModelLog("\(type(of: self)) resumed with missed updates; fired once")
        }
    }

    // MARK: - Public API

    /// Resolve or create a ViewModel and subscribe to its notifications.
    @discardableResult
    public func watch<VM: ViewModel>(_ factory: any ViewModelFactory<VM>) -> VM {
        getViewModel(factory: factory, listen: true)
    }

    /// Resolve or create a ViewModel without subscribing. Reference count is still incremented.
    @discardableResult
    public func read<VM: ViewModel>(_ factory: any ViewModelFactory<VM>) -> VM {
        getViewModel(factory: factory, listen: false)
    }

    /// Find an already-created ViewModel by key or tag and subscribe. Throws on miss.
    public func watchCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) throws -> VM {
        try requireExistingViewModel(arg: InstanceArg(key: key, tag: tag), listen: true)
    }

    /// Like `watchCached` but does not subscribe.
    public func readCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) throws -> VM {
        try requireExistingViewModel(arg: InstanceArg(key: key, tag: tag), listen: false)
    }

    public func maybeWatchCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) -> VM? {
        try? watchCached(key: key, tag: tag)
    }

    public func maybeReadCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) -> VM? {
        try? readCached(key: key, tag: tag)
    }

    /// Batch fetch by tag, subscribing to each matched instance.
    public func watchCachesByTag<VM: ViewModel>(_ tag: AnyHashable) -> [VM] {
        let vms: [VM] = instanceController.getInstancesByTag(VM.self, tag: tag, observeRecreate: true)
        for vm in vms { addListener(vm) }
        return vms
    }

    /// Batch fetch by tag without subscribing. Instances are still bound so lifecycle
    /// cleanup happens on dispose; recreation events are still observed.
    public func readCachesByTag<VM: ViewModel>(_ tag: AnyHashable) -> [VM] {
        instanceController.getInstancesByTag(VM.self, tag: tag, observeRecreate: true)
    }

    public func listen<VM: ViewModel>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping () -> Void
    ) {
        let vm = read(factory)
        addSubscription(vm) { value in value.listen(onChanged: onChanged) }
    }

    public func listenState<VM, S>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping (S?, S) -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        addSubscription(vm) { value in value.listenState(onChanged: onChanged) }
    }

    public func listenStateSelect<VM, S, R: Equatable>(
        _ factory: any ViewModelFactory<VM>,
        selector: @escaping (S) -> R,
        onChanged: @escaping (R?, R) -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        addSubscription(vm) { value in
            value.listenStateSelect(selector: selector, onChanged: onChanged)
        }
    }

    /// Force-dispose a specific ViewModel. Subsequent `watch` / `read` calls will
    /// rebuild it.
    public func recycle<VM: ViewModel>(_ viewModel: VM) {
        precondition(
            InstanceManager.shared.recycle(viewModel),
            "Cannot recycle \(VM.self): instance not found in registry."
        )
    }

    /// Replace one managed object while preserving all active owner paths.
    @discardableResult
    public func recreate<VM: ViewModel>(
        _ viewModel: VM,
        builder: (@MainActor () -> VM)? = nil
    ) throws -> VM {
        let owner = viewModel.refHandler.primaryOwner ?? self
        return try ViewModelBinding.withBuilding(owner) {
            try InstanceManager.shared.recreate(viewModel, builder: builder)
        }
    }

    // MARK: - Pause provider management

    public func addPauseProvider(_ provider: any ViewModelBindingPauseProvider) {
        _pauseController.addProvider(provider)
    }

    public func removePauseProvider(_ provider: any ViewModelBindingPauseProvider) {
        _pauseController.removeProvider(provider)
    }

    // MARK: - Teardown

    open func dispose() {
        if isDisposed { return }
        isDisposed = true
        for disposer in Array(watchedViewModels.values) { disposer() }
        watchedViewModels.removeAll()
        for subscription in subscriptions { subscription.dispose() }
        subscriptions.removeAll()
        for d in disposes {
            d()
        }
        disposes.removeAll()
        _pauseController.dispose()
        instanceController.dispose()
    }

    // MARK: - Internals

    /// Generic resolve: key → cache hit, else factory → create, else tag → cache hit.
    private func getViewModel<VM: ViewModel>(
        factory: (any ViewModelFactory<VM>)? = nil,
        arg: InstanceArg = InstanceArg(),
        listen: Bool
    ) -> VM {
        precondition(!isDisposed, "Cannot get \(VM.self): binding is disposed.")

        if let key = arg.key {
            do {
                return try requireExistingViewModel(arg: InstanceArg(key: key), listen: listen)
            } catch {
                if factory == nil, arg.tag == nil {
                    preconditionFailure("\(VM.self) instance not found for key=\(key)")
                }
            }
        }

        if let factory {
            return createViewModel(factory: factory, listen: listen)
        }

        do {
            return try requireExistingViewModel(arg: InstanceArg(tag: arg.tag), listen: listen)
        } catch {
            preconditionFailure("\(VM.self) instance not found for tag=\(String(describing: arg.tag))")
        }
    }

    /// Throws when no ViewModel matches the supplied lookup criteria.
    private func requireExistingViewModel<VM: ViewModel>(
        arg: InstanceArg,
        listen: Bool
    ) throws -> VM {
        precondition(!isDisposed, "Cannot get \(VM.self): binding is disposed.")
        let vm: VM = try instanceController.getInstance(
            VM.self,
            factory: InstanceFactory<VM>(arg: arg)
        )
        if listen {
            addListener(vm)
        }
        return vm
    }

    /// Creates a ViewModel using the supplied factory.
    ///
    /// The full registry call runs with this binding on the construction stack,
    /// covering both `init()` and `onCreate(_:)`. A ViewModel that resolves a
    /// child during construction creates its own stable dependency binding and
    /// uses the stack only to discover the initial external owner. Afterward,
    /// that generation-owned binding is independent of any particular root.
    private func createViewModel<VM: ViewModel>(
        factory: any ViewModelFactory<VM>,
        listen: Bool
    ) -> VM {
        precondition(!isDisposed, "Cannot create \(VM.self): binding is disposed.")
        let configuredKey = factory.key()
        let tag = factory.tag()
        let aliveForever = factory.aliveForever()
        if let validationError = Self.aliveForeverKeyValidationError(
            configuredKey: configuredKey,
            aliveForever: aliveForever
        ) {
            preconditionFailure(validationError)
        }
        let key = configuredKey ?? defaultViewModelKey

        let instanceFactory = InstanceFactory<VM>(
            builder: { factory.build() },
            arg: InstanceArg(key: key, tag: tag, aliveForever: aliveForever)
        )

        let vm: VM
        do {
            vm = try ViewModelBinding.withBuilding(self) {
                try instanceController.getInstance(VM.self, factory: instanceFactory)
            }
        } catch {
            preconditionFailure("ViewModel create failed: \(error)")
        }

        if listen {
            addListener(vm)
        }
        return vm
    }

    /// Attach a generic listener that forwards every `notifyListeners` call to
    /// `onUpdate()`. Calls are deduplicated per VM.
    private func addListener(_ vm: ViewModel) {
        let key = ObjectIdentifier(vm)
        if watchedViewModels[key] != nil { return }
        let disposer = vm.listen(onChanged: { [weak self, weak vm] in
            guard let self, let vm else { return }
            if self.isDisposed { return }
            if self._pauseController.isPaused {
                self.hasMissedUpdates = true
                viewModelLog("\(type(of: self)) paused, delay rebuild")
                return
            }
            if markViewModelBindingUpdated(self) {
                self.onViewModelUpdate(vm)
            }
        })
        watchedViewModels[key] = disposer
    }

    private func addSubscription<VM: ViewModel>(
        _ viewModel: VM,
        attach: @escaping (VM) -> () -> Void
    ) {
        subscriptions.append(BindingSubscription(
            viewModel: viewModel,
            attach: { value in attach(value as! VM) }
        ))
    }

    private func onViewModelUpdate(_ viewModel: ViewModel) {
        if let viewModelUpdateHook {
            viewModelUpdateHook(viewModel)
        } else {
            onUpdate()
        }
    }

    func installDependencyHooks(
        attached: @escaping (any _AnyHandle, ViewModel) -> Void,
        detached: @escaping (any _AnyHandle, ViewModel) -> Void,
        recreated: @escaping (any _AnyHandle, ViewModel, ViewModel) -> Void,
        updated: @escaping (ViewModel) -> Void
    ) {
        instanceAttachedHook = attached
        instanceDetachedHook = detached
        instanceRecreatedHook = recreated
        viewModelUpdateHook = updated
    }
}

@MainActor
private final class BindingSubscription {
    private var viewModel: ViewModel
    private let attach: (ViewModel) -> () -> Void
    private var disposer: (() -> Void)?

    init(viewModel: ViewModel, attach: @escaping (ViewModel) -> () -> Void) {
        self.viewModel = viewModel
        self.attach = attach
        disposer = attach(viewModel)
    }

    func isAttached(to value: ViewModel) -> Bool { viewModel === value }

    func move(to value: ViewModel) {
        disposer?()
        viewModel = value
        disposer = attach(value)
    }

    func dispose() {
        disposer?()
        disposer = nil
    }
}

// MARK: - @_spi(Internal) access for framework-internal call sites

@_spi(Internal)
public extension ViewModelBinding {
    /// Bind a VM to this binding's lifetime without going through `watch` / `read`.
    /// Used by the pause provider plumbing and other internal tests.
    func _registerListenerDisposer(_ disposer: @escaping () -> Void) {
        disposes.append(disposer)
    }
}
