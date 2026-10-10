import XCTest
@_spi(Internal) @testable import AppleViewModel

@MainActor
private final class BindingResolutionProbe {
    var hashesWhileResolving = 0
}

/// Observe entry into the existing registry/construction context without a
/// production-only counter or assumptions about Dictionary's hash call count.
private struct BindingResolutionKey: Hashable {
    let value: String
    let probe: BindingResolutionProbe

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }

    func hash(into hasher: inout Hasher) {
        MainActor.assumeIsolated {
            if ViewModelBinding.currentBuilding != nil {
                probe.hashesWhileResolving += 1
            }
        }
        hasher.combine(value)
    }
}

@MainActor
private final class BindingResolutionArgViewModel: ViewModel {
    let argument: String

    init(argument: String) {
        self.argument = argument
        super.init()
    }
}

@MainActor
private final class BindingResolutionParentViewModel: ViewModel {
    private let childSpec: ViewModelSpec<CounterViewModel>

    init(childSpec: ViewModelSpec<CounterViewModel>) {
        self.childSpec = childSpec
        super.init()
    }

    var child: CounterViewModel { viewModelBinding.read(childSpec) }
}

@MainActor
private final class BindingResolutionResetViewModel: ViewModel {
    var onUnbinding: (() -> Void)?

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        let callback = onUnbinding
        onUnbinding = nil
        callback?()
    }
}

@MainActor
final class BindingResolutionCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_warmFactoryReadsAndWatchesSkipRegistryResolutionAndSubscribeOnce() {
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        let probe = BindingResolutionProbe()
        let key = BindingResolutionKey(value: "observed", probe: probe)
        let spec = ViewModelSpec<CounterViewModel>(key: AnyHashable(key)) {
            CounterViewModel()
        }
        var refreshes = 0
        binding.refresh = { refreshes += 1 }
        let viewModel = binding.read(spec)

        XCTAssertGreaterThan(probe.hashesWhileResolving, 0, "The cold resolve must exercise the probe")
        viewModel.increment()
        XCTAssertEqual(refreshes, 0, "Reading owns the instance without subscribing")

        probe.hashesWhileResolving = 0
        for _ in 0..<8 {
            XCTAssertTrue(binding.read(spec) === viewModel)
            XCTAssertTrue(binding.watch(spec) === viewModel)
        }

        XCTAssertEqual(probe.hashesWhileResolving, 0, "A warm factory hit skips registry resolution")
        XCTAssertEqual(viewModel.onCreateCalls, 1)
        XCTAssertEqual(viewModel.onBindCalls, 1)
        viewModel.increment()
        XCTAssertEqual(refreshes, 1, "Read-to-watch promotion installs one subscription")
        XCTAssertTrue(binding.read(spec) === viewModel)
        viewModel.increment()
        XCTAssertEqual(refreshes, 2, "A later read does not remove the watch subscription")
    }

    func test_unkeyedSpecsAndArgumentsShareTypeIdentityOnlyWithinOneBinding() {
        let owner = ViewModelBinding()
        let otherOwner = ViewModelBinding()
        defer {
            owner.dispose()
            otherOwner.dispose()
        }
        var builds = 0
        let firstSpec = ViewModelSpec<BindingResolutionArgViewModel> {
            builds += 1
            return BindingResolutionArgViewModel(argument: "first")
        }
        let secondSpec = ViewModelSpec<BindingResolutionArgViewModel> {
            builds += 1
            return BindingResolutionArgViewModel(argument: "second")
        }
        let argSpec = ViewModelSpecWithArg<BindingResolutionArgViewModel, String>(
            builder: { argument in
                builds += 1
                return BindingResolutionArgViewModel(argument: argument)
            }
        )
        let first = owner.read(firstSpec)

        XCTAssertTrue(owner.watch(secondSpec) === first)
        XCTAssertTrue(owner.read(argSpec("argument-one")) === first)
        XCTAssertTrue(owner.watch(argSpec("argument-two")) === first)
        XCTAssertEqual(first.argument, "first")
        XCTAssertEqual(builds, 1)

        let other = otherOwner.read(argSpec("other-owner"))
        XCTAssertFalse(other === first)
        XCTAssertEqual(other.argument, "other-owner")
        XCTAssertEqual(builds, 2)
    }

    func test_cacheIdentityIncludesTypeAndCurrentEffectiveKey() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "shared-key") { CounterViewModel() }
        let otherTypeSpec = ViewModelSpec<CounterStateViewModel>(key: "shared-key") {
            CounterStateViewModel()
        }
        let overrideSpec = ViewModelSpec<CounterViewModel>(key: "override-key") {
            CounterViewModel()
        }
        let original = binding.read(spec)
        let otherType = binding.read(otherTypeSpec)
        original.increment()
        XCTAssertEqual(otherType.state.count, 0)
        XCTAssertTrue(binding.read(otherTypeSpec) === otherType)

        let restore = spec.overrideWith(overrideSpec)
        defer { restore() }
        let overridden = binding.watch(spec)
        XCTAssertFalse(overridden === original)
        XCTAssertTrue(binding.read(overrideSpec) === overridden)
        restore()

        XCTAssertTrue(binding.read(spec) === original)
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(original.onBindCalls, 1)
    }

    func test_aliveForeverValidationRunsBeforeReturningWarmUnkeyedEntry() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let existing = binding.read(spec)
        var invalidBuilds = 0
        let invalid = ViewModelSpec<CounterViewModel>(aliveForever: true) {
            invalidBuilds += 1
            return CounterViewModel()
        }
        let restore = spec.overrideWith(invalid)
        defer { restore() }

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertTrue(error is ViewModelError)
            XCTAssertTrue(String(describing: error).contains("explicit key"))
        }
        XCTAssertThrowsError(try binding.watchThrowing(spec)) { error in
            XCTAssertTrue(error is ViewModelError)
            XCTAssertTrue(String(describing: error).contains("explicit key"))
        }
        XCTAssertEqual(invalidBuilds, 0)
        XCTAssertFalse(existing.isDisposed)
        restore()
        XCTAssertTrue(binding.read(spec) === existing)
    }

    func test_recycleInvalidatesAllOwnersAndRestoresTheirWatchSubscriptions() {
        let owner = HostedViewModelBinding()
        let otherOwner = HostedViewModelBinding()
        defer {
            owner.dispose()
            otherOwner.dispose()
        }
        let spec = ViewModelSpec<CounterViewModel>(key: "recycled-shared") { CounterViewModel() }
        var ownerRefreshes = 0
        var otherRefreshes = 0
        owner.refresh = { ownerRefreshes += 1 }
        otherOwner.refresh = { otherRefreshes += 1 }
        let first = owner.watch(spec)
        XCTAssertTrue(otherOwner.watch(spec) === first)
        XCTAssertTrue(owner.watch(spec) === first)
        XCTAssertTrue(otherOwner.watch(spec) === first)

        owner.recycle(first)

        XCTAssertTrue(first.isDisposed)
        XCTAssertEqual(first.onDisposeCalls, 1)
        XCTAssertEqual(ownerRefreshes, 1)
        XCTAssertEqual(otherRefreshes, 1)
        let replacement = owner.watch(spec)
        XCTAssertFalse(replacement === first)
        XCTAssertTrue(otherOwner.watch(spec) === replacement)
        ownerRefreshes = 0
        otherRefreshes = 0
        replacement.increment()
        XCTAssertEqual(ownerRefreshes, 1)
        XCTAssertEqual(otherRefreshes, 1)

        owner.dispose()
        XCTAssertFalse(replacement.isDisposed)
        otherOwner.dispose()
        XCTAssertTrue(replacement.isDisposed)
        XCTAssertEqual(replacement.onDisposeCalls, 1)
    }

    func test_resetInvalidatesWarmResolutionInExistingBinding() {
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        var builds = 0
        let spec = ViewModelSpec<CounterViewModel> {
            builds += 1
            return CounterViewModel()
        }
        var refreshes = 0
        binding.refresh = { refreshes += 1 }
        let first = binding.watch(spec)
        XCTAssertTrue(binding.read(spec) === first)

        ViewModel.reset()

        XCTAssertTrue(first.isDisposed)
        XCTAssertEqual(refreshes, 0, "Reset tears down bindings without notifying their hosts")
        let replacement = binding.watch(spec)
        XCTAssertFalse(replacement === first)
        XCTAssertTrue(binding.read(spec) === replacement)
        XCTAssertEqual(builds, 2)
        replacement.increment()
        XCTAssertEqual(refreshes, 1)
    }

    func test_resetRejectsWarmPeerResolutionBeforeThatPeerBeginsDisposal() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let firstSpec = ViewModelSpec<BindingResolutionResetViewModel>(key: "reset-first") {
            BindingResolutionResetViewModel()
        }
        let secondSpec = ViewModelSpec<BindingResolutionResetViewModel>(key: "reset-second") {
            BindingResolutionResetViewModel()
        }
        let first = binding.read(firstSpec)
        let second = binding.read(secondSpec)
        let firstHandle = try InstanceManager.shared.getHandle(
            BindingResolutionResetViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "reset-first"))
        )
        let secondHandle = try InstanceManager.shared.getHandle(
            BindingResolutionResetViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "reset-second"))
        )
        var livePeerAttempts = 0
        var successes = 0
        var errors: [Error] = []
        first.onUnbinding = { [weak secondHandle] in
            if secondHandle?.isDisposed == false { livePeerAttempts += 1 }
            do {
                _ = try binding.readThrowing(secondSpec)
                successes += 1
            } catch { errors.append(error) }
        }
        second.onUnbinding = { [weak firstHandle] in
            if firstHandle?.isDisposed == false { livePeerAttempts += 1 }
            do {
                _ = try binding.watchThrowing(firstSpec)
                successes += 1
            } catch { errors.append(error) }
        }

        ViewModel.reset()

        // Whichever handle resets first, its peer is still live and cached.
        // The reset guard must reject that otherwise-valid fast-path hit.
        XCTAssertGreaterThan(livePeerAttempts, 0)
        XCTAssertEqual(successes, 0)
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.allSatisfy { $0 is ViewModelError })
        XCTAssertTrue(first.isDisposed)
        XCTAssertTrue(second.isDisposed)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }

    func test_warmResolutionRestoresDirectHandleOwnershipAlongsideParentOwnership() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = ViewModelSpec<CounterViewModel>(key: "handle-child") { CounterViewModel() }
        let parentSpec = ViewModelSpec<BindingResolutionParentViewModel> {
            BindingResolutionParentViewModel(childSpec: childSpec)
        }
        let parent = owner.read(parentSpec)
        let child = parent.child
        XCTAssertTrue(owner.read(childSpec) === child)
        let handle = try InstanceManager.shared.getHandle(
            CounterViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "handle-child"))
        )
        handle.unbind(owner.id)
        XCTAssertTrue(handle.contains(bindingId: owner.id), "The parent's source still owns the child")

        XCTAssertTrue(owner.read(childSpec) === child)
        owner.recycle(parent)

        XCTAssertFalse(child.isDisposed, "The new read must restore direct ownership before the parent leaves")
        XCTAssertTrue(child.refHandler.externalOwners.contains { $0 === owner })
        owner.dispose()
        XCTAssertTrue(child.isDisposed)
    }

    func test_warmResolutionRestoresDirectRefWhenOnlyParentRefRemains() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = ViewModelSpec<CounterViewModel>(key: "ref-child") { CounterViewModel() }
        let parentSpec = ViewModelSpec<BindingResolutionParentViewModel> {
            BindingResolutionParentViewModel(childSpec: childSpec)
        }
        let parent = owner.read(parentSpec)
        let child = parent.child
        XCTAssertTrue(owner.read(childSpec) === child)
        child.refHandler.removeRef(owner)
        XCTAssertTrue(child.refHandler.externalOwners.contains { $0 === owner })

        XCTAssertTrue(owner.watch(childSpec) === child)
        owner.recycle(parent)

        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(
            child.refHandler.externalOwners.contains { $0 === owner },
            "The root's direct ref must survive removal of the parent's propagated source"
        )
        owner.dispose()
        XCTAssertTrue(child.isDisposed)
    }

    func test_disposedBindingCannotReturnItsPreviouslyCachedSharedInstance() {
        let owner = ViewModelBinding()
        let keeper = ViewModelBinding()
        defer {
            owner.dispose()
            keeper.dispose()
        }
        let spec = ViewModelSpec<CounterViewModel>(key: "still-owned") { CounterViewModel() }
        let viewModel = owner.watch(spec)
        XCTAssertTrue(keeper.read(spec) === viewModel)

        owner.dispose()

        XCTAssertFalse(viewModel.isDisposed)
        XCTAssertThrowsError(try owner.readThrowing(spec))
        XCTAssertThrowsError(try owner.watchThrowing(spec))
        XCTAssertTrue(keeper.read(spec) === viewModel)
    }
}
