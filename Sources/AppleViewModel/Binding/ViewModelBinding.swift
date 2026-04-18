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

    // MARK: - TaskLocal dependency context

    /// Current binding captured by the registry while a ViewModel is being built.
    /// Equivalent to the Dart `runWithBinding` / `Zone.current[#view_model_binding]`
    /// pattern — a builder running inside
    /// `ViewModelBinding.$current.withValue(self) { … }` sees `self` on this key.
    @TaskLocal public static var current: ViewModelBinding?

    /// Internal hook used by `ViewModelBindingHandler` to resolve the current binding.
    @_spi(Internal) public static var _currentTaskLocal: ViewModelBinding? { current }

    // MARK: - Identity and state

    /// Globally unique id used to key reference counts on `InstanceHandle`.
    public let id: String = "Binding#\(UUID().uuidString)"

    public private(set) var isDisposed: Bool = false

    public var isPaused: Bool { pauseController.isPaused }

    /// Registered VMs for which we are listening to `notifyListeners`.
    /// Used to de-duplicate repeated `addListener` calls on the same VM.
    private var watchedViewModels: [ObjectIdentifier: Bool] = [:]

    /// Per-subscription teardown closures (from `listen`, `listenState`, etc.).
    private var disposes: [() -> Void] = []

    /// Set to true when a notification arrives while we are paused. Drained on resume.
    private var hasMissedUpdates: Bool = false

    private lazy var instanceController: AutoDisposeInstanceController = {
        AutoDisposeInstanceController(binding: self, onRecreate: { [weak self] in
            self?.onUpdate()
        })
    }()

    private lazy var _pauseController: PauseAwareController = makePauseController()

    public var pauseController: PauseAwareController { _pauseController }

    public init() {}

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
        let vms: [VM] = instanceController.getInstancesByTag(VM.self, tag: tag, listen: true)
        for vm in vms { addListener(vm) }
        return vms
    }

    /// Batch fetch by tag without subscribing. Instances are still bound so lifecycle
    /// cleanup happens on dispose; recreation events are still observed.
    public func readCachesByTag<VM: ViewModel>(_ tag: AnyHashable) -> [VM] {
        instanceController.getInstancesByTag(VM.self, tag: tag, listen: true)
    }

    public func listen<VM: ViewModel>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping () -> Void
    ) {
        let vm = read(factory)
        let disposer = vm.listen(onChanged: onChanged)
        disposes.append(disposer)
    }

    public func listenState<VM, S>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping (S?, S) -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        let disposer = vm.listenState(onChanged: onChanged)
        disposes.append(disposer)
    }

    public func listenStateSelect<VM, S, R: Equatable>(
        _ factory: any ViewModelFactory<VM>,
        selector: @escaping (S) -> R,
        onChanged: @escaping (R?, R) -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        let disposer = vm.listenStateSelect(selector: selector, onChanged: onChanged)
        disposes.append(disposer)
    }

    /// Force-dispose a specific ViewModel. Subsequent `watch` / `read` calls will
    /// rebuild it.
    public func recycle<VM: ViewModel>(_ viewModel: VM) {
        instanceController.recycle(viewModel)
        onUpdate()
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
        watchedViewModels.removeAll()
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

    /// Creates a ViewModel using the supplied factory inside a `TaskLocal` binding
    /// context so that `viewModelBinding` references inside the VM's init resolve to
    /// this binding.
    private func createViewModel<VM: ViewModel>(
        factory: any ViewModelFactory<VM>,
        listen: Bool
    ) -> VM {
        precondition(!isDisposed, "Cannot create \(VM.self): binding is disposed.")
        let key: AnyHashable = factory.key() ?? AnyHashable(UUID())
        let tag = factory.tag()
        let aliveForever = factory.aliveForever()

        let instanceFactory = InstanceFactory<VM>(
            builder: { [weak self] in
                guard let self else {
                    preconditionFailure("Binding released during VM build")
                }
                return ViewModelBinding.$current.withValue(self) {
                    factory.build()
                }
            },
            arg: InstanceArg(key: key, tag: tag, aliveForever: aliveForever)
        )

        let vm: VM
        do {
            vm = try instanceController.getInstance(VM.self, factory: instanceFactory)
        } catch {
            preconditionFailure("ViewModel create failed: \(error)")
        }
        // SPI-only access; treat as internal plumbing for dependency resolution.
        withInternal { vm.refHandler.addRef(self) }

        if listen {
            addListener(vm)
        }
        return vm
    }

    /// Attach a generic listener that forwards every `notifyListeners` call to
    /// `onUpdate()`. Calls are deduplicated per VM.
    private func addListener(_ vm: ViewModel) {
        let key = ObjectIdentifier(vm)
        if watchedViewModels[key] == true { return }
        watchedViewModels[key] = true
        let disposer = vm.listen(onChanged: { [weak self] in
            guard let self else { return }
            if self.isDisposed { return }
            if self._pauseController.isPaused {
                self.hasMissedUpdates = true
                viewModelLog("\(type(of: self)) paused, delay rebuild")
                return
            }
            self.onUpdate()
        })
        disposes.append(disposer)
    }

    /// Helper that runs a `@_spi(Internal)` block inline so callers can stay terse.
    private func withInternal(_ body: () -> Void) {
        body()
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
