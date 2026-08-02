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

    private var instanceAttachedHook: ((any _AnyHandle, ViewModel) throws -> Void)?
    private var instanceDetachedHook: ((any _AnyHandle, ViewModel) -> Void)?
    private var viewModelUpdateHook: ((ViewModel) -> Void)?
    private let defaultViewModelKey = AnyHashable(ViewModelPrivateKey())

    private lazy var instanceController: AutoDisposeInstanceController = {
        AutoDisposeInstanceController(
            binding: self,
            onHandleDisposing: { [weak self] in self?.handleInstanceChange() },
            onInstanceAttached: { [weak self] handle, viewModel in
                try self?.handleInstanceAttached(handle, viewModel: viewModel)
            },
            onInstanceDetached: { [weak self] handle, viewModel in
                self?.handleInstanceDetached(handle, viewModel: viewModel)
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

    private func handleInstanceAttached(_ handle: any _AnyHandle, viewModel: ViewModel) throws {
        try instanceAttachedHook?(handle, viewModel)
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

    /// Primary resolution API. Resolve or create from a stable spec/factory,
    /// establish ownership, and subscribe to ViewModel notifications.
    @discardableResult
    public func watch<VM: ViewModel>(_ factory: any ViewModelFactory<VM>) -> VM {
        failFastResolution { try watchThrowing(factory) }
    }

    /// Recoverable counterpart of `watch(_:)`.
    ///
    /// Builder failures, reset conflicts, and dependency-cycle validation are
    /// surfaced to the caller without terminating the process.
    @discardableResult
    public func watchThrowing<VM: ViewModel>(
        _ factory: any ViewModelFactory<VM>
    ) throws -> VM {
        try getViewModel(factory: factory, listen: true)
    }

    /// Primary resolution API. Resolve or create from a stable spec/factory
    /// without subscribing to ViewModel notifications. Ownership and handle
    /// disposal observation are still established.
    @discardableResult
    public func read<VM: ViewModel>(_ factory: any ViewModelFactory<VM>) -> VM {
        failFastResolution { try readThrowing(factory) }
    }

    /// Recoverable counterpart of `read(_:)`.
    @discardableResult
    public func readThrowing<VM: ViewModel>(
        _ factory: any ViewModelFactory<VM>
    ) throws -> VM {
        try getViewModel(factory: factory, listen: false)
    }

    /// Advanced lookup-only API. Find an already-created ViewModel by key or tag
    /// and subscribe. Throws on miss and never creates an instance. Prefer
    /// `watch(_:)` with a stable spec for normal dependency resolution.
    public func watchCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) throws -> VM {
        try getViewModel(
            arg: InstanceArg(key: key, tag: tag),
            listen: true
        )
    }

    /// Advanced lookup-only API. Like `watchCached` but does not subscribe.
    /// Prefer `read(_:)` with a stable spec for normal dependency resolution.
    public func readCached<VM: ViewModel>(key: AnyHashable? = nil, tag: AnyHashable? = nil) throws -> VM {
        try getViewModel(
            arg: InstanceArg(key: key, tag: tag),
            listen: false
        )
    }

    /// Advanced lookup-only API that returns `nil` on a cache miss.
    /// Prefer `watch(_:)` with a stable spec for normal dependency resolution.
    public func maybeWatchCached<VM: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) -> VM? {
        try? maybeWatchCachedThrowing(key: key, tag: tag)
    }

    /// Recoverable counterpart of `maybeWatchCached` that preserves unexpected
    /// non-ViewModel errors. The source-compatible non-throwing API remains the
    /// convenient lookup form used by existing callers.
    public func maybeWatchCachedThrowing<VM: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) throws -> VM? {
        do {
            return try watchCached(key: key, tag: tag)
        } catch is ViewModelError {
            return nil
        } catch {
            throw error
        }
    }

    /// Advanced lookup-only API that returns `nil` on a cache miss.
    /// Prefer `read(_:)` with a stable spec for normal dependency resolution.
    public func maybeReadCached<VM: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) -> VM? {
        try? maybeReadCachedThrowing(key: key, tag: tag)
    }

    /// Recoverable counterpart of `maybeReadCached` that preserves unexpected
    /// non-ViewModel errors.
    public func maybeReadCachedThrowing<VM: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) throws -> VM? {
        do {
            return try readCached(key: key, tag: tag)
        } catch is ViewModelError {
            return nil
        } catch {
            throw error
        }
    }

    /// Advanced lookup-only API. Fetch every existing instance with a tag and
    /// subscribe to each match. Prefer specs for normal dependency resolution.
    public func watchCachesByTag<VM: ViewModel>(_ tag: AnyHashable) -> [VM] {
        failFastResolution { try watchCachesByTagThrowing(tag) }
    }

    /// Recoverable counterpart of `watchCachesByTag(_:)`.
    public func watchCachesByTagThrowing<VM: ViewModel>(
        _ tag: AnyHashable
    ) throws -> [VM] {
        let vms: [VM] = try instanceController.getInstancesByTag(VM.self, tag: tag)
        for vm in vms { addListener(vm) }
        return vms
    }

    /// Advanced lookup-only API. Fetch every existing instance with a tag
    /// without subscribing. Instances are still bound so lifecycle cleanup
    /// happens on dispose; handle disposal is still observed. Prefer specs
    /// for normal dependency resolution.
    public func readCachesByTag<VM: ViewModel>(_ tag: AnyHashable) -> [VM] {
        failFastResolution { try readCachesByTagThrowing(tag) }
    }

    /// Recoverable counterpart of `readCachesByTag(_:)`.
    public func readCachesByTagThrowing<VM: ViewModel>(
        _ tag: AnyHashable
    ) throws -> [VM] {
        try instanceController.getInstancesByTag(VM.self, tag: tag)
    }

    public func listen<VM: ViewModel>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping () throws -> Void
    ) {
        let vm = read(factory)
        addSubscription(vm) { value in value.listen(onChanged: onChanged) }
    }

    public func listenState<VM, S>(
        _ factory: any ViewModelFactory<VM>,
        onChanged: @escaping (S?, S) throws -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        addSubscription(vm) { value in value.listenState(onChanged: onChanged) }
    }

    public func listenStateSelect<VM, S, R: Equatable>(
        _ factory: any ViewModelFactory<VM>,
        selector: @escaping (S) -> R,
        equals: ((R, R) -> Bool)? = nil,
        onChanged: @escaping (R?, R) throws -> Void
    ) where VM: StateViewModel<S> {
        let vm = read(factory)
        addSubscription(vm) { value in
            value.listenStateSelect(
                selector: selector,
                equals: equals,
                onChanged: onChanged
            )
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
    ) throws -> VM {
        guard !isDisposed else {
            throw ViewModelError("Cannot get \(VM.self): binding is disposed.")
        }

        if let key = arg.key {
            do {
                return try requireExistingViewModel(arg: InstanceArg(key: key), listen: listen)
            } catch let error as ViewModelError {
                if factory == nil, arg.tag == nil {
                    throw error
                }
            }
        }

        if let factory {
            return try createViewModel(factory: factory, listen: listen)
        }

        return try requireExistingViewModel(
            arg: InstanceArg(tag: arg.tag),
            listen: listen
        )
    }

    /// Throws when no ViewModel matches the supplied lookup criteria.
    private func requireExistingViewModel<VM: ViewModel>(
        arg: InstanceArg,
        listen: Bool
    ) throws -> VM {
        guard !isDisposed else {
            throw ViewModelError("Cannot get \(VM.self): binding is disposed.")
        }
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
    ) throws -> VM {
        guard !isDisposed else {
            throw ViewModelError("Cannot create \(VM.self): binding is disposed.")
        }
        let configuredKey = factory.key()
        let tag = factory.tag()
        let aliveForever = factory.aliveForever()
        if let validationError = Self.aliveForeverKeyValidationError(
            configuredKey: configuredKey,
            aliveForever: aliveForever
        ) {
            throw ViewModelError(validationError)
        }
        let key = configuredKey ?? defaultViewModelKey

        let instanceFactory = InstanceFactory<VM>(
            builder: { try factory.buildThrowing() },
            arg: InstanceArg(key: key, tag: tag, aliveForever: aliveForever)
        )

        let vm = try ViewModelBinding.withBuilding(self) {
            try instanceController.getInstance(VM.self, factory: instanceFactory)
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
        attached: @escaping (any _AnyHandle, ViewModel) throws -> Void,
        detached: @escaping (any _AnyHandle, ViewModel) -> Void,
        updated: @escaping (ViewModel) -> Void
    ) {
        instanceAttachedHook = attached
        instanceDetachedHook = detached
        viewModelUpdateHook = updated
    }

    private func failFastResolution<Result>(
        _ operation: () throws -> Result
    ) -> Result {
        do {
            return try operation()
        } catch {
            preconditionFailure("ViewModel resolution failed: \(error)")
        }
    }
}

@MainActor
private final class BindingSubscription {
    private let viewModel: ViewModel
    private var disposer: (() -> Void)?

    init(viewModel: ViewModel, attach: @escaping (ViewModel) -> () -> Void) {
        self.viewModel = viewModel
        disposer = attach(viewModel)
    }

    func isAttached(to value: ViewModel) -> Bool { viewModel === value }

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
