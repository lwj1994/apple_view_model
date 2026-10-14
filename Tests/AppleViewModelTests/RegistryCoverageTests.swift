import XCTest
@_spi(Internal) @testable import AppleViewModel

private enum RegistryCoverageError: Error { case listener, attachment }

@MainActor
private final class HandleLifecycleProbe: NSObject, InstanceLifeCycle {
    var events: [String] = []
    var created: (() -> Void)?
    func onCreate(_ arg: InstanceArg) { events.append("create"); created?() }
    func onBind(_ arg: InstanceArg, bindingId: String) { events.append("bind:\(bindingId)") }
    func onUnbind(_ arg: InstanceArg, bindingId: String) { events.append("unbind:\(bindingId)") }
    func onDispose(_ arg: InstanceArg) { events.append("dispose") }
}

@MainActor
private final class DefaultLifecycleObserver: ViewModelLifecycle {}

@MainActor
private final class ReleasingCoverageViewModel: CounterViewModel {
    var bound: ((String) -> Void)?
    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        bound?(bindingId)
    }
}

@MainActor
final class RegistryCoverageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_handleDirectAndPropagatedSourcesReleaseIndependently() throws {
        let value = HandleLifecycleProbe()
        let handle = InstanceHandle(value: value, arg: InstanceArg(bindingId: "root"), index: 0)
        let first = NSObject()
        let second = NSObject()
        handle.bind(nil)
        handle.bind("root")
        handle.bindFrom(nil, source: first)
        handle.bindFrom("root", source: first)
        handle.bindFrom("root", source: first)
        handle.bindFrom("root", source: second)
        XCTAssertEqual(value.events, ["create", "bind:root"])
        XCTAssertTrue(try handle.requireInstance() === value)
        handle.unbind("root")
        handle.unbind("root")
        handle.unbindFrom("missing", source: first)
        handle.unbindFrom("root", source: NSObject())
        handle.unbindFrom("root", source: first)
        XCTAssertFalse(handle.isDisposed)
        XCTAssertTrue(handle.contains(bindingId: "root"))
        handle.unbindFrom("root", source: second)
        XCTAssertEqual(value.events, ["create", "bind:root", "unbind:root", "dispose"])
        XCTAssertTrue(handle.isDisposed)
        XCTAssertThrowsError(try handle.requireInstance())
        handle.bind("late")
        handle.bindFrom("late", source: first)
        handle.unbindFrom("root", source: second)
        XCTAssertTrue(handle.bindingIds.isEmpty)
    }

    func test_handleListenerErrorsAndCancellationDoNotSkipLaterCleanup() {
        let value = HandleLifecycleProbe()
        let handle = InstanceHandle(value: value, arg: InstanceArg(bindingId: "root"), index: 0)
        var callbacks: [String] = []
        var cancelSecond: (() -> Void)?
        let cancelFirst = handle.addListener { _ in
            callbacks.append("first")
            cancelSecond?()
            throw RegistryCoverageError.listener
        }
        cancelSecond = handle.addListener { _ in callbacks.append("cancelled") }
        _ = handle.addListener { _ in callbacks.append("last") }
        handle.unbindAll(force: true)
        XCTAssertEqual(callbacks, ["first", "last"])
        XCTAssertEqual(value.events.last, "dispose")
        handle.addListener { _ in XCTFail("Disposed handles must not notify") }()
        cancelFirst()
    }

    func test_disposedOwnerCannotAttachToHandle() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let handle = InstanceHandle(value: NSObject(), arg: InstanceArg(), index: 0)
        owner.dispose()
        XCTAssertThrowsError(try handle.bindOwner(owner))
        handle.unbindAll(force: true)
        XCTAssertThrowsError(try handle.bindOwner(owner))
    }

    func test_disposedStoreRejectsResolutionAndReturnsNoMatches() throws {
        let store = Store<NSObject>()
        store.dispose()
        XCTAssertTrue(store.instances(byTag: "tag").isEmpty)
        XCTAssertEqual(store.countInstances(), 0)
        XCTAssertThrowsError(try store.findNewlyInstance())
        XCTAssertThrowsError(try store.getHandle(factory: InstanceFactory(builder: { NSObject() })))
        XCTAssertFalse(store.tryRecycle(NSObject()))
    }

    func test_storeDisposedByOnCreateReclaimsTentativeInstance() {
        let store = Store<HandleLifecycleProbe>()
        let value = HandleLifecycleProbe()
        value.created = { store.dispose() }
        XCTAssertThrowsError(try store.getHandle(factory: InstanceFactory(builder: { value })))
        XCTAssertEqual(value.events, ["create", "dispose"])
        XCTAssertTrue(store.isEmpty)
    }

    func test_managerOptionalLookupReturnsValueOrNilAndUnknownRecycleIsFalse() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        XCTAssertNil(InstanceManager.shared.maybeGet(CounterViewModel.self))
        let spec = ViewModelSpec<CounterViewModel>(key: "optional") { CounterViewModel() }
        let vm = owner.read(spec)
        XCTAssertTrue(InstanceManager.shared.maybeGet(CounterViewModel.self) === vm)
        XCTAssertFalse(InstanceManager.shared.recycle(NSObject()))
        owner.dispose()
        XCTAssertNil(InstanceManager.shared.maybeGet(CounterViewModel.self))
    }

    func test_controllerRejectsDisposedBindingAndVisitsLiveViewModels() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let controller = AutoDisposeInstanceController(binding: owner, onHandleDisposing: {})
        defer { controller.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "controller") { CounterViewModel() }
        let vm = try controller.getInstance(CounterViewModel.self, factory: InstanceFactory(
            builder: { spec.build() }, arg: InstanceArg(key: "controller")
        ))
        var visited: [ObjectIdentifier] = []
        controller.performForAllInstances { visited.append(ObjectIdentifier($0)) }
        XCTAssertEqual(visited, [ObjectIdentifier(vm)])
        controller.dispose()
        XCTAssertTrue(vm.isDisposed)
        owner.dispose()
        XCTAssertThrowsError(try controller.getInstance(CounterViewModel.self, factory: InstanceFactory()))
        XCTAssertThrowsError(try controller.getInstancesByTag(CounterViewModel.self, tag: "tag"))
        controller.performForAllInstances { _ in XCTFail("Disposed registrations must not be visited") }
    }

    func test_ownerDiagnosticsHandleDuplicateSourcesCancellationAndErrors() {
        let first = ViewModelBinding()
        let second = ViewModelBinding()
        defer { first.dispose(); second.dispose() }
        let handler = ViewModelBindingHandler()
        defer { handler.dispose() }
        let source = NSObject()
        var notifications: [[String]] = []
        var cancelSecond: (() -> Void)?
        let cancelFirst = handler.addOwnerChangeListener { ids, _, _ in
            notifications.append(ids)
            cancelSecond?()
            throw RegistryCoverageError.listener
        }
        cancelSecond = handler.addOwnerChangeListener { _, _, _ in XCTFail("Cancelled listener ran") }
        handler.addRef(first)
        handler.addRef(first)
        handler.addRef(first, source: source)
        XCTAssertTrue(handler.binding === first)
        handler.removeRef(first)
        XCTAssertTrue(handler.binding === first)
        handler.addRef(second)
        handler.removeRef(first, source: source)
        XCTAssertTrue(handler.binding === second)
        XCTAssertEqual(notifications, [[first.id], [first.id, second.id], [second.id]])
        cancelFirst()
        handler.removeRef(second)
        XCTAssertTrue(handler.owners.isEmpty)
        ViewModelBinding.withBuilding(first) { XCTAssertTrue(handler.binding === first) }
    }

    func test_staticCacheFallbackAndManualDisposedInstanceAreReported() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "static", tag: "fallback") { CounterViewModel() }
        let vm = owner.read(spec)
        let byTag: CounterViewModel = try ViewModel.readCached(key: "missing", tag: "fallback")
        XCTAssertTrue(byTag === vm)
        XCTAssertThrowsError(try ViewModel.readCached(key: "missing") as CounterViewModel)
        vm.onDispose(vm.instanceArg)
        XCTAssertThrowsError(try ViewModel.readCached(key: "static") as CounterViewModel)
        XCTAssertNil(try ViewModel.maybeReadCachedThrowing(key: "static") as CounterViewModel?)
    }

    func test_tagConvenienceAPIsAttachAndNotifyOnlyWatchers() {
        let creator = ViewModelBinding()
        let reader = HostedViewModelBinding()
        let watcher = HostedViewModelBinding()
        defer { creator.dispose(); reader.dispose(); watcher.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "tag-member", tag: "group") { CounterViewModel() }
        let vm = creator.read(spec)
        var reads = 0
        var watches = 0
        reader.refresh = { reads += 1 }
        watcher.refresh = { watches += 1 }
        let read: [CounterViewModel] = reader.readCachesByTag("group")
        let watched: [CounterViewModel] = watcher.watchCachesByTag("group")
        XCTAssertTrue(read.first === vm)
        XCTAssertTrue(watched.first === vm)
        vm.increment()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(watches, 1)
        creator.dispose()
        XCTAssertFalse(vm.isDisposed)
    }

    func test_unexpectedAttachmentErrorsPropagateThroughOptionalCachedAPIs() throws {
        let creator = ViewModelBinding()
        let consumer = ViewModelBinding()
        defer { creator.dispose(); consumer.dispose() }
        let vm = creator.read(ViewModelSpec<CounterViewModel>(key: "attachment") { CounterViewModel() })
        consumer.installDependencyHooks(
            attaching: { _, _ in throw RegistryCoverageError.attachment },
            attached: { _, _ in nil }, detached: { _, _ in nil }, updated: { _ in }
        )
        XCTAssertThrowsError(try consumer.maybeReadCachedThrowing(key: "attachment") as CounterViewModel?) {
            XCTAssertTrue($0 is RegistryCoverageError)
        }
        XCTAssertThrowsError(try consumer.maybeWatchCachedThrowing(key: "attachment") as CounterViewModel?) {
            XCTAssertTrue($0 is RegistryCoverageError)
        }
        XCTAssertFalse(vm.isDisposed)
        XCTAssertEqual(vm.onBindCalls, 1)
    }

    func test_deepDependencyCycleIsRejectedBeforeAttaching() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let a = owner.read(ViewModelSpec<CounterViewModel>(key: "a") { CounterViewModel() })
        let bSpec = ViewModelSpec<CounterViewModel>(key: "b") { CounterViewModel() }
        let cSpec = ViewModelSpec<CounterViewModel>(key: "c") { CounterViewModel() }
        let b = a.viewModelBinding.read(bSpec)
        let c = b.viewModelBinding.read(cSpec)
        XCTAssertThrowsError(try c.viewModelBinding.readCached(key: "a") as CounterViewModel)
        XCTAssertEqual(a.onBindCalls, 1)
        XCTAssertFalse(a.isDisposed)
    }

    func test_loggingIsLazyAndLifecycleDefaultsCanBeRemoved() {
        var evaluations = 0
        func message() -> String { evaluations += 1; return "coverage diagnostic" }
        viewModelLog(message())
        XCTAssertEqual(evaluations, 0)
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        viewModelLog(message())
        XCTAssertEqual(evaluations, 1)
        let observer = DefaultLifecycleObserver()
        let removeObserver = ViewModel.addLifecycle(observer)
        defer { removeObserver() }
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        _ = owner.read(ViewModelSpec { CounterViewModel() })
        owner.dispose()
        ViewModel.removeLifecycle(observer)
        ViewModel.debugReset()
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        XCTAssertFalse(ViewModel.config.isLoggingEnabled)
    }

    func test_registeredDisposersRunOnceInOrder() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var calls: [Int] = []
        binding._registerListenerDisposer { calls.append(1) }
        binding._registerListenerDisposer { calls.append(2) }
        binding.dispose()
        binding.dispose()
        XCTAssertEqual(calls, [1, 2])
    }

    func test_disposalDuringKeyLookupRejectsTagFallback() {
        let creator = ViewModelBinding()
        let consumer = ViewModelBinding()
        defer { creator.dispose(); consumer.dispose() }
        _ = creator.read(ViewModelSpec<CounterViewModel>(key: "key", tag: "tag") { CounterViewModel() })
        consumer.installDependencyHooks(
            attaching: { _, _ in
                consumer.dispose()
                throw ViewModelError("Disposed during key lookup")
            },
            attached: { _, _ in nil }, detached: { _, _ in nil }, updated: { _ in }
        )
        XCTAssertThrowsError(try consumer.readCached(key: "key", tag: "tag") as CounterViewModel) {
            XCTAssertTrue(String(describing: $0).contains("Disposed during key lookup"))
        }
    }

    func test_controllerRejectsOwnershipReleasedFromOnBindForNewAndRepairedRegistrations() throws {
        for repairExisting in [false, true] {
            let keeper = ViewModelBinding()
            let consumer = ViewModelBinding()
            defer { keeper.dispose(); consumer.dispose() }
            let spec = ViewModelSpec<ReleasingCoverageViewModel>(key: "released-\(repairExisting)") {
                ReleasingCoverageViewModel()
            }
            let vm = keeper.read(spec)
            let factory = InstanceFactory<ReleasingCoverageViewModel>(arg: InstanceArg(key: spec.key()))
            let handle = try InstanceManager.shared.getHandle(ReleasingCoverageViewModel.self, factory: factory)
            let controller = AutoDisposeInstanceController(binding: consumer, onHandleDisposing: {})
            defer { controller.dispose() }
            if repairExisting {
                _ = try controller.getInstance(ReleasingCoverageViewModel.self, factory: factory)
                handle.unbindOwner(consumer)
            }
            vm.bound = { id in
                if id == consumer.id { handle.unbindOwner(consumer) }
            }
            defer { vm.bound = nil }
            XCTAssertThrowsError(try controller.getInstance(ReleasingCoverageViewModel.self, factory: factory)) {
                XCTAssertTrue(String(describing: $0).contains("Ownership was released"))
            }
            XCTAssertFalse(handle.containsDirectBinding(consumer.id))
            XCTAssertFalse(vm.refHandler.hasDirectRef(consumer))
            XCTAssertTrue(handle.containsDirectBinding(keeper.id))
            XCTAssertFalse(vm.isDisposed)
        }
    }

    func test_factoryCopyPreservesMetadataAndCanOverrideBuilder() throws {
        let original = NSObject()
        let replacement = NSObject()
        let factory = InstanceFactory(builder: { original }, arg: InstanceArg(key: "copy", tag: "tag"))
        let copy = factory.copy()
        XCTAssertTrue(try copy.builder?() === original)
        XCTAssertEqual(copy.arg.key, "copy")
        XCTAssertEqual(copy.arg.tag, "tag")
        let changed = factory.copy(builder: { replacement })
        XCTAssertTrue(try changed.builder?() === replacement)
        XCTAssertEqual(changed.arg.key, "copy")
    }

    func test_diagnosticMessagesAreEvaluatedForPausedAndDisposedInstances() async throws {
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        let binding = HostedViewModelBinding()
        let provider = BasePauseProvider()
        defer { binding.dispose(); provider.dispose() }
        binding.addPauseProvider(provider)
        let vm = binding.watch(ViewModelSpec { CounterStateViewModel() })
        var updates = 0
        binding.refresh = { updates += 1 }
        provider.pause()
        for _ in 0..<100 where !binding.isPaused {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(binding.isPaused)
        vm.inc()
        XCTAssertEqual(updates, 0)
        provider.resume()
        for _ in 0..<100 where binding.isPaused {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(binding.isPaused)
        XCTAssertEqual(updates, 1)
        binding.dispose()
        vm.notifyListeners()
        vm.inc()
        XCTAssertEqual(vm.state.count, 1)
        XCTAssertEqual(updates, 1)

        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let first = ViewModelSpec<CounterViewModel>(key: "log-first", tag: "log") { CounterViewModel() }
        let second = ViewModelSpec<CounterViewModel>(key: "log-second", tag: "log") { CounterViewModel() }
        _ = owner.read(first)
        let latest = owner.read(second)
        let found: CounterViewModel = try ViewModel.readCached(tag: "log")
        XCTAssertTrue(found === latest)
    }
}
