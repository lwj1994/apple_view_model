import XCTest
@testable import AppleViewModel

@MainActor
final class ParentDependencyBindingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_sharedParent_propagatesOwnerChangesWithoutSwitchingChildGeneration() {
        let ownerA = ViewModelBinding()
        let parent = ownerA.read(pdParentSpec)
        let child = parent.child
        let dependencyBindingId = child.boundIds.first { $0 != ownerA.id }!

        let ownerB = ViewModelBinding()
        XCTAssertTrue(ownerB.read(pdParentSpec) === parent)
        XCTAssertTrue(child.boundIds.contains(ownerB.id))
        XCTAssertTrue(parent.child === child)

        ownerA.dispose()
        XCTAssertFalse(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(parent.child === child)
        XCTAssertTrue(child.unboundIds.contains(ownerA.id))

        ownerB.dispose()
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(
            Set(child.unboundIds),
            Set([dependencyBindingId, ownerA.id, ownerB.id])
        )
    }

    func test_directAndParentPathsFromOneRoot_areReleasedIndependently() {
        let owner = ViewModelBinding()
        let directChild = owner.read(pdSharedChildSpec)
        let parent = owner.read(pdParentSpec)
        XCTAssertTrue(parent.sharedChild === directChild)

        owner.recycle(parent)

        XCTAssertTrue(parent.isDisposed)
        XCTAssertFalse(directChild.isDisposed)
        XCTAssertFalse(directChild.unboundIds.contains(owner.id))
        XCTAssertTrue(owner.read(pdSharedChildSpec) === directChild)

        owner.dispose()
        XCTAssertTrue(directChild.isDisposed)
    }

    func test_rootCanGloballyRecycleChildOwnedOnlyThroughParent() {
        let owner = PDCountingBinding()
        let parent = owner.watch(pdParentSpec)
        let child = parent.child
        owner.updates = 0

        owner.recycle(child)

        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(parent.dependencyNotifications, 1)
        XCTAssertEqual(owner.updates, 1)
        XCTAssertFalse(parent.child === child)
        owner.dispose()
    }

    func test_readDoesNotBubbleAndWatchBubblesOnce() {
        let owner = PDCountingBinding()
        let parent = owner.watch(pdParentSpec)
        let child = parent.child
        owner.updates = 0

        child.emit()
        XCTAssertEqual(parent.dependencyNotifications, 0)
        XCTAssertEqual(owner.updates, 0)

        XCTAssertTrue(parent.watchedChild === child)
        child.emit()
        XCTAssertEqual(parent.dependencyNotifications, 1)
        XCTAssertEqual(owner.updates, 1)
        owner.dispose()
    }

    func test_sharedParentOwnsOneWatchSubscriptionForAllRoots() {
        let ownerA = PDCountingBinding()
        let parent = ownerA.watch(pdParentSpec)
        let child = parent.watchedChild
        let ownerB = PDCountingBinding()
        XCTAssertTrue(ownerB.watch(pdParentSpec) === parent)
        ownerA.updates = 0
        ownerB.updates = 0

        child.emit()

        XCTAssertEqual(parent.dependencyNotifications, 1)
        XCTAssertEqual(ownerA.updates, 1)
        XCTAssertEqual(ownerB.updates, 1)
        ownerA.dispose()
        ownerB.dispose()
    }

    func test_diamondPropagation_updatesEachBindingOncePerTransaction() {
        let owner = PDCountingBinding()
        let root = owner.watch(pdDiamondRootSpec)
        let left = root.left
        let right = root.right
        let leaf = left.leaf
        XCTAssertTrue(right.leaf === leaf)
        XCTAssertTrue(owner.watch(pdDiamondLeafSpec) === leaf)
        owner.updates = 0

        leaf.emit()

        XCTAssertEqual(left.dependencyNotifications, 1)
        XCTAssertEqual(right.dependencyNotifications, 1)
        XCTAssertEqual(root.dependencyNotifications, 1)
        XCTAssertEqual(owner.updates, 1)
        owner.dispose()
    }

    func test_keyedAliveForeverChildRemainsReachableAfterParentDisposal() {
        let owner = ViewModelBinding()
        let parent = owner.read(pdParentSpec)
        let child = parent.aliveKeyedChild
        owner.dispose()

        XCTAssertTrue(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)
        let next = ViewModelBinding()
        XCTAssertTrue(next.read(pdAliveKeyedChildSpec) === child)
        next.recycle(child)
        XCTAssertTrue(child.isDisposed)
        next.dispose()
    }

    func test_aliveForeverParentTransitivelyKeepsPrivateChildAlive() {
        let owner = ViewModelBinding()
        let parent = owner.read(pdAliveParentSpec)
        let child = parent.child
        owner.dispose()

        XCTAssertFalse(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)

        let next = ViewModelBinding()
        XCTAssertTrue(next.read(pdAliveParentSpec) === parent)
        XCTAssertTrue(parent.child === child)
        next.recycle(parent)
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(child.isDisposed)
        next.dispose()
    }
}

@MainActor
private final class PDChildViewModel: ViewModel {
    var boundIds: [String] = []
    var unboundIds: [String] = []

    func emit() { notifyListeners() }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        boundIds.append(bindingId)
    }

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        unboundIds.append(bindingId)
    }
}

@MainActor private let pdChildSpec = ViewModelSpec<PDChildViewModel> { PDChildViewModel() }
@MainActor private let pdSharedChildSpec = ViewModelSpec<PDChildViewModel>(
    key: "parent-shared-child"
) { PDChildViewModel() }
@MainActor private let pdAliveKeyedChildSpec = ViewModelSpec<PDChildViewModel>(
    key: "parent-alive-child",
    aliveForever: true
) { PDChildViewModel() }

@MainActor
private final class PDParentViewModel: ViewModel {
    var dependencyNotifications = 0
    var listenCallbacks = 0

    var child: PDChildViewModel { viewModelBinding.read(pdChildSpec) }
    var watchedChild: PDChildViewModel { viewModelBinding.watch(pdChildSpec) }
    var sharedChild: PDChildViewModel { viewModelBinding.read(pdSharedChildSpec) }
    var aliveKeyedChild: PDChildViewModel { viewModelBinding.read(pdAliveKeyedChildSpec) }

    func listenToChild() {
        viewModelBinding.listen(pdChildSpec) { [weak self] in
            self?.listenCallbacks += 1
        }
    }

    override func onDependencyNotify(_ viewModel: ViewModel) {
        dependencyNotifications += 1
    }
}

@MainActor private let pdParentSpec = ViewModelSpec<PDParentViewModel>(
    key: "parent-shared-parent"
) { PDParentViewModel() }
@MainActor private let pdAliveParentSpec = ViewModelSpec<PDParentViewModel>(
    key: "parent-alive-parent",
    aliveForever: true
) { PDParentViewModel() }

@MainActor
private final class PDCountingBinding: ViewModelBinding {
    var updates = 0
    override func onUpdate() {
        super.onUpdate()
        updates += 1
    }
}

@MainActor private let pdDiamondLeafSpec = ViewModelSpec<PDChildViewModel>(
    key: "diamond-leaf"
) { PDChildViewModel() }

@MainActor
private final class PDDiamondBranch: ViewModel {
    var dependencyNotifications = 0
    var leaf: PDChildViewModel { viewModelBinding.watch(pdDiamondLeafSpec) }

    override func onDependencyNotify(_ viewModel: ViewModel) {
        dependencyNotifications += 1
    }
}

@MainActor private let pdLeftBranchSpec = ViewModelSpec<PDDiamondBranch>(
    key: "diamond-left"
) { PDDiamondBranch() }
@MainActor private let pdRightBranchSpec = ViewModelSpec<PDDiamondBranch>(
    key: "diamond-right"
) { PDDiamondBranch() }

@MainActor
private final class PDDiamondRoot: ViewModel {
    var dependencyNotifications = 0
    var left: PDDiamondBranch { viewModelBinding.watch(pdLeftBranchSpec) }
    var right: PDDiamondBranch { viewModelBinding.watch(pdRightBranchSpec) }

    override func onDependencyNotify(_ viewModel: ViewModel) {
        dependencyNotifications += 1
    }
}

@MainActor private let pdDiamondRootSpec = ViewModelSpec<PDDiamondRoot>(
    key: "diamond-root"
) { PDDiamondRoot() }
