import XCTest
@_spi(Internal) @testable import AppleViewModel

@MainActor
private final class UnbindParentViewModel: ViewModel {
    private let childSpec: ViewModelSpec<CounterViewModel>

    init(childSpec: ViewModelSpec<CounterViewModel>) {
        self.childSpec = childSpec
        super.init()
    }

    var child: CounterViewModel { viewModelBinding.read(childSpec) }
}

private final class BindingSelectedRecord {
    let id: Int

    init(id: Int) { self.id = id }
}

@MainActor
final class BindingOwnershipParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_unbindReleasesOnlyRequestedInstanceAndCanResolveFreshGeneration() {
        let owner = HostedViewModelBinding()
        defer { owner.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "released") { CounterViewModel() }
        let siblingSpec = ViewModelSpec<CounterViewModel>(key: "kept") { CounterViewModel() }
        let first = owner.watch(spec)
        let sibling = owner.watch(siblingSpec)
        var refreshes = 0
        owner.refresh = { refreshes += 1 }

        owner.unbind(first)

        XCTAssertTrue(first.isDisposed)
        XCTAssertEqual(first.onDisposeCalls, 1)
        XCTAssertFalse(sibling.isDisposed)
        XCTAssertEqual(refreshes, 0, "Explicit unbind does not request a host refresh")
        sibling.increment()
        XCTAssertEqual(refreshes, 1)

        let replacement = owner.watch(spec)
        XCTAssertFalse(replacement === first)
        owner.unbind(first)
        XCTAssertFalse(replacement.isDisposed, "An old generation cannot unbind its replacement")
        replacement.increment()
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(first.onDisposeCalls, 1)
    }

    func test_unbindRemovesOnlyLocalWatchAndBusinessSubscriptions() {
        let owner = HostedViewModelBinding()
        let keeper = HostedViewModelBinding()
        defer {
            owner.dispose()
            keeper.dispose()
        }
        let spec = ViewModelSpec<CounterStateViewModel>(key: "shared-state") {
            CounterStateViewModel()
        }
        var ownerRefreshes = 0
        var keeperRefreshes = 0
        var broadEvents = 0
        var stateEvents = 0
        var selectedEvents = 0
        owner.refresh = { ownerRefreshes += 1 }
        keeper.refresh = { keeperRefreshes += 1 }
        let value = owner.watch(spec)
        XCTAssertTrue(keeper.watch(spec) === value)
        owner.listen(spec) { broadEvents += 1 }
        owner.listenState(spec) { _, _ in stateEvents += 1 }
        owner.listenStateSelect(spec, selector: { $0.count }) { _, _ in selectedEvents += 1 }

        value.inc()
        XCTAssertEqual(ownerRefreshes, 1)
        XCTAssertEqual(keeperRefreshes, 1)
        XCTAssertEqual([broadEvents, stateEvents, selectedEvents], [1, 1, 1])

        owner.unbind(value)
        owner.unbind(value)
        XCTAssertFalse(value.isDisposed)
        value.inc()
        XCTAssertEqual(ownerRefreshes, 1)
        XCTAssertEqual(keeperRefreshes, 2)
        XCTAssertEqual([broadEvents, stateEvents, selectedEvents], [1, 1, 1])

        XCTAssertTrue(owner.watch(spec) === value)
        value.inc()
        XCTAssertEqual(ownerRefreshes, 2, "Rewatch installs exactly one fresh watch")
        XCTAssertEqual(keeperRefreshes, 3)
        XCTAssertEqual([broadEvents, stateEvents, selectedEvents], [1, 1, 1],
                       "Explicit business subscriptions must be registered again")
        owner.unbind(value)
        keeper.unbind(value)
        XCTAssertTrue(value.isDisposed)
    }

    func test_unbindDirectChildKeepsParentSourceAndReadRestoresDirectOwnership() throws {
        let owner = HostedViewModelBinding()
        defer { owner.dispose() }
        let childSpec = ViewModelSpec<CounterViewModel>(key: "shared-child") { CounterViewModel() }
        let parentSpec = ViewModelSpec<UnbindParentViewModel> {
            UnbindParentViewModel(childSpec: childSpec)
        }
        let parent = owner.read(parentSpec)
        let child = parent.child
        XCTAssertTrue(owner.watch(childSpec) === child)
        let handle = try InstanceManager.shared.getHandle(
            CounterViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "shared-child"))
        )
        var refreshes = 0
        owner.refresh = { refreshes += 1 }

        owner.unbind(child)

        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(handle.contains(bindingId: owner.id))
        XCTAssertFalse(handle.containsDirectBinding(owner.id))
        XCTAssertFalse(child.refHandler.hasDirectRef(owner))
        child.increment()
        XCTAssertEqual(refreshes, 0)

        XCTAssertTrue(owner.watch(childSpec) === child)
        XCTAssertTrue(handle.containsDirectBinding(owner.id))
        XCTAssertTrue(child.refHandler.hasDirectRef(owner))
        owner.unbind(parent)
        XCTAssertTrue(parent.isDisposed)
        XCTAssertFalse(child.isDisposed, "Restored direct ownership survives the parent")
        child.increment()
        XCTAssertEqual(refreshes, 1)
        owner.unbind(child)
        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(child.onDisposeCalls, 1)
    }

    func test_unbindRetainedInstanceKeepsCacheAndIgnoresUnrelatedOwner() {
        let owner = HostedViewModelBinding()
        let unrelated = ViewModelBinding()
        defer {
            owner.dispose()
            unrelated.dispose()
        }
        let spec = ViewModelSpec<CounterViewModel>(key: "retained", aliveForever: true) {
            CounterViewModel()
        }
        let value = owner.watch(spec)
        unrelated.unbind(value)
        XCTAssertEqual(value.onUnbindCalls, 0)

        owner.unbind(value)
        XCTAssertFalse(value.isDisposed)
        XCTAssertEqual(value.onUnbindCalls, 1)
        XCTAssertFalse(value.hasListeners)
        XCTAssertTrue(owner.read(spec) === value)
        XCTAssertEqual(value.onCreateCalls, 1)
        XCTAssertEqual(value.onBindCalls, 2)
        owner.recycle(value)
        XCTAssertTrue(value.isDisposed)
        XCTAssertEqual(value.onDisposeCalls, 1)
    }

    func test_bindingSelectorAcceptsCustomEqualityForNonEquatableValues() {
        let owner = ViewModelBinding()
        let keeper = ViewModelBinding()
        defer {
            owner.dispose()
            keeper.dispose()
        }
        let spec = ViewModelSpec<StateViewModel<BindingSelectedRecord>>(key: "selected-record") {
            StateViewModel(state: BindingSelectedRecord(id: 1))
        }
        let value = keeper.read(spec)
        var transitions: [[Int]] = []
        owner.listenStateSelect(
            spec,
            selector: { $0 },
            equals: { $0.id == $1.id }
        ) { previous, current in
            transitions.append([previous.id, current.id])
        }

        value.setState(BindingSelectedRecord(id: 1))
        value.setState(BindingSelectedRecord(id: 2))
        XCTAssertEqual(transitions, [[1, 2]])
        owner.unbind(value)
        value.setState(BindingSelectedRecord(id: 3))
        XCTAssertEqual(transitions, [[1, 2]], "Unbind cleans up the custom selector subscription")
    }
}
