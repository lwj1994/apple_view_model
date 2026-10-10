import XCTest
@_spi(Internal) @testable import AppleViewModel

@MainActor
private final class DependencyUnbindChildViewModel: CounterViewModel {
    var unbindAction: ((String) -> Void)?

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        let action = unbindAction
        unbindAction = nil
        action?(bindingId)
    }
}

@MainActor
private final class DependencyUnbindParentViewModel: ViewModel {
    private let childSpec: ViewModelSpec<DependencyUnbindChildViewModel>

    init(childSpec: ViewModelSpec<DependencyUnbindChildViewModel>) {
        self.childSpec = childSpec
        super.init()
    }

    var child: DependencyUnbindChildViewModel { viewModelBinding.read(childSpec) }
}

@MainActor
final class DependencyUnbindParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_parentUnbindReleasesChildWhileRootAndParentRemainAlive() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = makeChildSpec()
        let parent = owner.read(parentSpec(childSpec: childSpec))
        let child = parent.child

        parent.viewModelBinding.unbind(child)

        XCTAssertFalse(owner.isDisposed)
        XCTAssertFalse(parent.isDisposed)
        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(child.onDisposeCalls, 1)
        XCTAssertTrue(child.refHandler.owners.isEmpty)
        owner.dispose()
        XCTAssertEqual(child.onDisposeCalls, 1)
    }

    func test_parentUnbindPreservesDirectAndSecondParentOwnershipSeparately() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = makeChildSpec()
        let firstParent = owner.read(parentSpec(key: "first-parent", childSpec: childSpec))
        let secondParent = owner.read(parentSpec(key: "second-parent", childSpec: childSpec))
        let child = firstParent.child
        XCTAssertTrue(secondParent.child === child)
        XCTAssertTrue(owner.read(childSpec) === child)
        let handle = try InstanceManager.shared.getHandle(
            DependencyUnbindChildViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "shared-child"))
        )

        firstParent.viewModelBinding.unbind(child)

        XCTAssertFalse(child.isDisposed)
        XCTAssertFalse(handle.contains(bindingId: firstParent.viewModelBinding.id))
        XCTAssertTrue(handle.contains(bindingId: secondParent.viewModelBinding.id))
        XCTAssertTrue(handle.containsDirectBinding(owner.id))
        owner.unbind(child)
        XCTAssertFalse(child.isDisposed, "The second parent still owns its independent source")
        XCTAssertFalse(handle.containsDirectBinding(owner.id))
        XCTAssertTrue(handle.contains(bindingId: owner.id))
        secondParent.viewModelBinding.unbind(child)
        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(child.onDisposeCalls, 1)
        XCTAssertFalse(firstParent.isDisposed)
        XCTAssertFalse(secondParent.isDisposed)
    }

    func test_sharedParentUnbindRemovesEveryPropagatedRoot() {
        let firstOwner = ViewModelBinding()
        let secondOwner = ViewModelBinding()
        defer {
            firstOwner.dispose()
            secondOwner.dispose()
        }
        let childSpec = makeChildSpec()
        let sharedParentSpec = parentSpec(childSpec: childSpec)
        let parent = firstOwner.read(sharedParentSpec)
        let child = parent.child
        XCTAssertTrue(secondOwner.read(sharedParentSpec) === parent)
        XCTAssertEqual(child.refHandler.externalOwners.count, 2)

        parent.viewModelBinding.unbind(child)

        XCTAssertTrue(child.isDisposed)
        XCTAssertTrue(child.refHandler.owners.isEmpty)
        XCTAssertEqual(child.onUnbindCalls, 3, "The dependency binding and both roots leave once")
        XCTAssertFalse(parent.isDisposed)
        XCTAssertFalse(firstOwner.isDisposed)
        XCTAssertFalse(secondOwner.isDisposed)
    }

    func test_reboundChildIsReleasedWhenTheParentLaterDisposes() {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = makeChildSpec()
        let parent = owner.read(parentSpec(childSpec: childSpec))
        let original = parent.child
        parent.viewModelBinding.unbind(original)
        let replacement = parent.child

        XCTAssertTrue(original.isDisposed)
        XCTAssertFalse(replacement === original)
        XCTAssertFalse(replacement.isDisposed)
        owner.unbind(parent)
        XCTAssertFalse(owner.isDisposed)
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(replacement.isDisposed)
        XCTAssertEqual(original.onDisposeCalls, 1)
        XCTAssertEqual(replacement.onDisposeCalls, 1)
    }

    func test_ownerDiagnosticCanRebindDuringPropagatedRefRemoval() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = makeChildSpec()
        let parent = owner.read(parentSpec(childSpec: childSpec))
        let child = parent.child
        var rebinds = 0
        let removeListener = child.refHandler.addOwnerChangeListener { owners, _, _ in
            guard !owners.contains(owner.id), rebinds == 0 else { return }
            rebinds += 1
            XCTAssertTrue(parent.child === child)
        }
        defer { removeListener() }

        parent.viewModelBinding.unbind(child)

        let handle = try InstanceManager.shared.getHandle(
            DependencyUnbindChildViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "shared-child"))
        )
        XCTAssertEqual(rebinds, 1)
        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(handle.containsDirectBinding(parent.viewModelBinding.id))
        XCTAssertTrue(handle.contains(bindingId: owner.id))
        XCTAssertTrue(child.refHandler.hasDirectRef(parent.viewModelBinding))
        XCTAssertEqual(child.refHandler.externalOwners.map(\.id), [owner.id])
        removeListener()
        owner.dispose()
        XCTAssertTrue(child.isDisposed, "The reentrant attachment remains tracked for later teardown")
        XCTAssertEqual(child.onDisposeCalls, 1)
    }

    func test_onUnbindCanRebindDuringPropagatedHandleSourceRemoval() throws {
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let childSpec = makeChildSpec()
        let parent = owner.read(parentSpec(childSpec: childSpec))
        let child = parent.child
        var rebinds = 0
        child.unbindAction = { bindingId in
            XCTAssertEqual(bindingId, owner.id)
            rebinds += 1
            XCTAssertTrue(parent.child === child)
        }

        parent.viewModelBinding.unbind(child)

        let handle = try InstanceManager.shared.getHandle(
            DependencyUnbindChildViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "shared-child"))
        )
        XCTAssertEqual(rebinds, 1)
        XCTAssertFalse(child.isDisposed)
        XCTAssertTrue(handle.containsDirectBinding(parent.viewModelBinding.id))
        XCTAssertTrue(handle.contains(bindingId: owner.id))
        XCTAssertTrue(child.refHandler.hasDirectRef(parent.viewModelBinding))
        XCTAssertEqual(child.refHandler.externalOwners.map(\.id), [owner.id])
        owner.dispose()
        XCTAssertTrue(child.isDisposed)
        XCTAssertEqual(child.onDisposeCalls, 1)
    }

    private func makeChildSpec() -> ViewModelSpec<DependencyUnbindChildViewModel> {
        ViewModelSpec(key: "shared-child") { DependencyUnbindChildViewModel() }
    }

    private func parentSpec(
        key: String = "parent",
        childSpec: ViewModelSpec<DependencyUnbindChildViewModel>
    ) -> ViewModelSpec<DependencyUnbindParentViewModel> {
        ViewModelSpec(key: key) { DependencyUnbindParentViewModel(childSpec: childSpec) }
    }
}
