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
        let ownerB = ViewModelBinding()
        defer {
            ownerA.dispose()
            ownerB.dispose()
        }
        let parent = ownerA.read(pdParentSpec)
        let child = parent.child
        let dependencyBindingId = child.boundIds.first { $0 != ownerA.id }!

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
        defer { owner.dispose() }
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
        defer { owner.dispose() }
        let parent = owner.watch(pdParentSpec)
        let child = parent.child
        var notifications = 0
        let cancel = parent.listen { notifications += 1 }
        defer { cancel() }
        owner.updates = 0

        owner.recycle(child)

        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(owner.updates, 1)
        XCTAssertFalse(parent.child === child)
    }

    func test_readDoesNotForwardAndWatchRefreshesBindingOnce() {
        let owner = PDCountingBinding()
        defer { owner.dispose() }
        let parent = owner.watch(pdParentSpec)
        let child = parent.child
        var notifications = 0
        let cancel = parent.listen { notifications += 1 }
        defer { cancel() }
        owner.updates = 0

        child.emit()
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(owner.updates, 0)

        XCTAssertTrue(parent.watchedChild === child)
        child.emit()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(owner.updates, 1)
    }

    func test_rootReadDoesNotSubscribeToWatchedChildNotifications() {
        let owner = PDCountingBinding()
        defer { owner.dispose() }
        let parent = owner.read(pdParentSpec)
        let child = parent.watchedChild
        var notifications = 0
        let cancel = parent.listen { notifications += 1 }
        defer { cancel() }

        child.emit()

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(owner.updates, 0, "ownership alone must not subscribe a root")
    }

    func test_sharedParentOwnsOneWatchSubscriptionForAllRoots() {
        let ownerA = PDCountingBinding()
        let ownerB = PDCountingBinding()
        defer {
            ownerA.dispose()
            ownerB.dispose()
        }
        let parent = ownerA.watch(pdParentSpec)
        let child = parent.watchedChild
        XCTAssertTrue(ownerB.watch(pdParentSpec) === parent)
        var notifications = 0
        let cancel = parent.listen { notifications += 1 }
        defer { cancel() }
        ownerA.updates = 0
        ownerB.updates = 0

        child.emit()

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(ownerA.updates, 1)
        XCTAssertEqual(ownerB.updates, 1)

        ownerA.dispose()
        child.emit()
        XCTAssertTrue(parent.watchedChild === child)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(ownerA.updates, 1)
        XCTAssertEqual(ownerB.updates, 2)
    }

    func test_diamondPropagation_updatesEachBindingOncePerTransaction() {
        let owner = PDCountingBinding()
        defer { owner.dispose() }
        let root = owner.watch(pdDiamondRootSpec)
        let left = root.left
        let right = root.right
        let leaf = left.leaf
        XCTAssertTrue(right.leaf === leaf)
        XCTAssertTrue(owner.watch(pdDiamondLeafSpec) === leaf)
        var leftNotifications = 0
        var rightNotifications = 0
        var rootNotifications = 0
        let cancelLeft = left.listen { leftNotifications += 1 }
        let cancelRight = right.listen { rightNotifications += 1 }
        let cancelRoot = root.listen { rootNotifications += 1 }
        defer {
            cancelLeft()
            cancelRight()
            cancelRoot()
        }
        owner.updates = 0

        leaf.emit()

        XCTAssertEqual(leftNotifications, 1)
        XCTAssertEqual(rightNotifications, 1)
        XCTAssertEqual(rootNotifications, 1)
        XCTAssertEqual(owner.updates, 1)
    }

    func test_businessReactionUsesExplicitChildListener() {
        let owner = PDCountingBinding()
        defer { owner.dispose() }
        let parent = owner.watch(pdParentSpec)
        parent.listenToChild()
        let child = parent.child

        child.emit()

        XCTAssertEqual(parent.listenCallbacks, 1)
        XCTAssertEqual(owner.updates, 0, "listen does not implicitly notify the parent")

        XCTAssertTrue(parent.watchedChild === child)
        child.emit()
        XCTAssertEqual(parent.listenCallbacks, 2)
        XCTAssertEqual(owner.updates, 1, "watch still forwards independently of business listeners")
    }

    func test_explicitListenerIsNotMigratedAfterChildRecycle() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let parent = owner.read(pdParentSpec)
        parent.listenToChild()
        let child = parent.child
        child.emit()
        XCTAssertEqual(parent.listenCallbacks, 1)

        owner.recycle(child)
        let replacement = parent.child
        XCTAssertFalse(replacement === child)
        replacement.emit()
        XCTAssertEqual(parent.listenCallbacks, 1)

        parent.listenToChild()
        replacement.emit()
        XCTAssertEqual(parent.listenCallbacks, 2)
    }

    func test_explicitListenerIsRemovedWhenParentDisposesButSharedChildSurvives() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let child = owner.read(pdSharedChildSpec)
        let parent = owner.read(pdParentSpec)
        var calls = 0
        parent.viewModelBinding.listen(pdSharedChildSpec) { calls += 1 }
        child.emit()
        XCTAssertEqual(calls, 1)

        owner.recycle(parent)
        XCTAssertTrue(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)
        child.emit()
        XCTAssertEqual(calls, 1)
    }

    func test_dependencyPauseResumesWithOneForwardedRefresh() async {
        let owner = PDCountingBinding()
        let provider = BasePauseProvider()
        defer {
            owner.dispose()
            provider.dispose()
        }
        let parent = owner.watch(pdParentSpec)
        let child = parent.watchedChild
        let dependencyBinding = parent.viewModelBinding
        dependencyBinding.addPauseProvider(provider)
        await yieldRunLoop()
        provider.pause()
        await yieldRunLoop()
        XCTAssertTrue(dependencyBinding.isPaused)

        child.emit()
        child.emit()
        XCTAssertEqual(owner.updates, 0)

        provider.resume()
        await yieldRunLoop()
        XCTAssertFalse(dependencyBinding.isPaused)
        XCTAssertEqual(owner.updates, 1)
    }

    func test_keyedAliveForeverChildRemainsReachableAfterParentDisposal() {
        let owner = ViewModelBinding()
        let next = ViewModelBinding()
        defer {
            owner.dispose()
            next.dispose()
        }
        let parent = owner.read(pdParentSpec)
        let child = parent.aliveKeyedChild
        owner.dispose()

        XCTAssertTrue(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(next.read(pdAliveKeyedChildSpec) === child)
        next.recycle(child)
        XCTAssertTrue(child.isDisposed)
    }

    func test_aliveForeverParentTransitivelyKeepsPrivateChildAlive() {
        let owner = ViewModelBinding()
        let next = ViewModelBinding()
        defer {
            owner.dispose()
            next.dispose()
        }
        let parent = owner.read(pdAliveParentSpec)
        let child = parent.child
        owner.dispose()

        XCTAssertFalse(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)

        XCTAssertTrue(next.read(pdAliveParentSpec) === parent)
        XCTAssertTrue(parent.child === child)
        next.recycle(parent)
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(child.isDisposed)
    }

    private func yieldRunLoop() async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await Task.yield()
        }
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
    var leaf: PDChildViewModel { viewModelBinding.watch(pdDiamondLeafSpec) }
}

@MainActor private let pdLeftBranchSpec = ViewModelSpec<PDDiamondBranch>(
    key: "diamond-left"
) { PDDiamondBranch() }
@MainActor private let pdRightBranchSpec = ViewModelSpec<PDDiamondBranch>(
    key: "diamond-right"
) { PDDiamondBranch() }

@MainActor
private final class PDDiamondRoot: ViewModel {
    var left: PDDiamondBranch { viewModelBinding.watch(pdLeftBranchSpec) }
    var right: PDDiamondBranch { viewModelBinding.watch(pdRightBranchSpec) }
}

@MainActor private let pdDiamondRootSpec = ViewModelSpec<PDDiamondRoot>(
    key: "diamond-root"
) { PDDiamondRoot() }
