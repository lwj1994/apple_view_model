import XCTest
@testable import AppleViewModel

@MainActor
private enum ExpectedResolutionError: Error, Equatable {
    case builder
    case parent
}

@MainActor
private final class WeakTestReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object? = nil) {
        self.value = value
    }
}

@MainActor
private final class RecoverableResolutionViewModel: ViewModel {}

@MainActor
private final class RollbackChildViewModel: ViewModel {
    static var created = 0
    static var disposed = 0

    override init() {
        Self.created += 1
        super.init()
    }

    override func dispose() {
        Self.disposed += 1
        super.dispose()
    }
}

@MainActor
private final class ThrowingParentViewModel: ViewModel {
    init(childSpec: ViewModelSpec<RollbackChildViewModel>) throws {
        super.init()
        _ = try viewModelBinding.readThrowing(childSpec)
        throw ExpectedResolutionError.parent
    }
}

@MainActor
private final class RecursiveResolutionViewModel: ViewModel {
    init(spec: ViewModelSpec<RecursiveResolutionViewModel>) throws {
        super.init()
        _ = try viewModelBinding.readThrowing(spec)
    }
}

@MainActor
private final class RuntimeCycleViewModel: ViewModel {
    func resolve(
        _ spec: ViewModelSpec<RuntimeCycleViewModel>
    ) throws -> RuntimeCycleViewModel {
        try viewModelBinding.readThrowing(spec)
    }
}

@MainActor
private final class RetainedCycleChildViewModel: ViewModel {
    init(parentSpec: ViewModelSpec<RuntimeCycleViewModel>) throws {
        super.init()
        _ = try viewModelBinding.readThrowing(parentSpec)
    }
}

@MainActor
private final class ResetReentrantViewModel: ViewModel {
    let binding: ViewModelBinding
    let dependencySpec: ViewModelSpec<RecoverableResolutionViewModel>
    var resolutionError: Error?

    init(
        binding: ViewModelBinding,
        dependencySpec: ViewModelSpec<RecoverableResolutionViewModel>
    ) {
        self.binding = binding
        self.dependencySpec = dependencySpec
        super.init()
    }

    override func dispose() {
        do {
            _ = try binding.readThrowing(dependencySpec)
        } catch {
            resolutionError = error
        }
        super.dispose()
    }
}

@MainActor
private enum ReentrantDisposePhase: CaseIterable {
    case onCreate
    case onBind
}

@MainActor
private final class LifecycleDisposesBindingViewModel: ViewModel {
    let binding: ViewModelBinding
    let phase: ReentrantDisposePhase

    init(binding: ViewModelBinding, phase: ReentrantDisposePhase) {
        self.binding = binding
        self.phase = phase
        super.init()
    }

    override func onCreate(_ arg: InstanceArg) {
        super.onCreate(arg)
        if phase == .onCreate { binding.dispose() }
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        if phase == .onBind { binding.dispose() }
    }
}

@MainActor
private final class OwnerRemovingOnBindViewModel: ViewModel {
    weak var ownerToDispose: ViewModelBinding?
    let targetBindingId: String

    init(ownerToDispose: ViewModelBinding) {
        self.ownerToDispose = ownerToDispose
        self.targetBindingId = ownerToDispose.id
        super.init()
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        guard bindingId == targetBindingId else { return }
        let owner = ownerToDispose
        ownerToDispose = nil
        owner?.dispose()
    }
}

@MainActor
private final class SelfRecyclingOnBindViewModel: ViewModel {
    weak var binding: ViewModelBinding?
    let targetBindingId: String
    let shouldRecycle: Bool

    init(binding: ViewModelBinding, shouldRecycle: Bool) {
        self.binding = binding
        self.targetBindingId = binding.id
        self.shouldRecycle = shouldRecycle
        super.init()
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        if shouldRecycle, bindingId == targetBindingId {
            binding?.recycle(self)
        }
    }
}

@MainActor
final class ThrowingResolutionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
        MainActor.assumeIsolated {
            RollbackChildViewModel.created = 0
            RollbackChildViewModel.disposed = 0
        }
    }

    func test_throwingBuilderPreservesOriginalErrorAndDoesNotCacheValue() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<RecoverableResolutionViewModel>(
            key: "recoverable-builder",
            throwingBuilder: { throw ExpectedResolutionError.builder }
        )

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertEqual(error as? ExpectedResolutionError, .builder)
        }
        XCTAssertThrowsError(
            try ViewModel.readCached(
                key: "recoverable-builder"
            ) as RecoverableResolutionViewModel
        )
    }

    func test_failedParentBuilderRollsBackItsManagedChild() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let childSpec = ViewModelSpec<RollbackChildViewModel> {
            RollbackChildViewModel()
        }
        let parentSpec = ViewModelSpec<ThrowingParentViewModel>(
            key: "throwing-parent",
            throwingBuilder: { try ThrowingParentViewModel(childSpec: childSpec) }
        )

        XCTAssertThrowsError(try binding.readThrowing(parentSpec)) { error in
            XCTAssertEqual(error as? ExpectedResolutionError, .parent)
        }
        XCTAssertEqual(RollbackChildViewModel.created, 1)
        XCTAssertEqual(RollbackChildViewModel.disposed, 1)
    }

    func test_constructionCycleIsRecoverableAndRegistryRemainsUsable() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var recursiveSpec: ViewModelSpec<RecursiveResolutionViewModel>!
        recursiveSpec = ViewModelSpec<RecursiveResolutionViewModel>(
            key: "recursive",
            throwingBuilder: {
                try RecursiveResolutionViewModel(spec: recursiveSpec)
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(recursiveSpec)) { error in
            XCTAssertTrue(String(describing: error).contains("Circular ViewModel construction"))
        }

        let healthySpec = ViewModelSpec<RecoverableResolutionViewModel>(
            key: "healthy-after-cycle"
        ) { RecoverableResolutionViewModel() }
        XCTAssertFalse(try binding.readThrowing(healthySpec).isDisposed)
    }

    func test_runtimeCycleAttachIsRejectedAtomically() throws {
        let binding = ViewModelBinding()
        let aSpec = ViewModelSpec<RuntimeCycleViewModel>(key: "runtime-a") {
            RuntimeCycleViewModel()
        }
        let bSpec = ViewModelSpec<RuntimeCycleViewModel>(key: "runtime-b") {
            RuntimeCycleViewModel()
        }
        let a = binding.read(aSpec)
        let b = binding.read(bSpec)

        XCTAssertTrue(try a.resolve(bSpec) === b)
        XCTAssertThrowsError(try b.resolve(aSpec)) { error in
            XCTAssertTrue(String(describing: error).contains("Circular ViewModel dependency"))
        }
        XCTAssertFalse(a.isDisposed)
        XCTAssertFalse(b.isDisposed)

        binding.dispose()
        XCTAssertTrue(a.isDisposed)
        XCTAssertTrue(b.isDisposed)
    }

    func test_failedAttachForceDisposesOnlyNewAliveForeverGeneration() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let parentSpec = ViewModelSpec<RuntimeCycleViewModel>(key: "retained-cycle-parent") {
            RuntimeCycleViewModel()
        }
        let parent = binding.read(parentSpec)
        var created: RetainedCycleChildViewModel?
        let childSpec = ViewModelSpec<RetainedCycleChildViewModel>(
            key: "retained-cycle-child",
            aliveForever: true,
            throwingBuilder: {
                let value = try RetainedCycleChildViewModel(parentSpec: parentSpec)
                created = value
                return value
            }
        )

        XCTAssertThrowsError(try parent.viewModelBinding.readThrowing(childSpec)) { error in
            XCTAssertTrue(String(describing: error).contains("Circular ViewModel dependency"))
        }
        XCTAssertEqual(created?.isDisposed, true)
        XCTAssertFalse(parent.isDisposed)
        XCTAssertThrowsError(
            try ViewModel.readCached(
                key: "retained-cycle-child"
            ) as RetainedCycleChildViewModel
        )
    }

    func test_resetBlocksReentrantResolution() {
        let binding = ViewModelBinding()
        let dependencySpec = ViewModelSpec<RecoverableResolutionViewModel>(
            key: "during-reset"
        ) { RecoverableResolutionViewModel() }
        let retainedSpec = ViewModelSpec<ResetReentrantViewModel>(
            key: "reset-reentrant",
            aliveForever: true
        ) {
            ResetReentrantViewModel(
                binding: binding,
                dependencySpec: dependencySpec
            )
        }
        let retained = binding.read(retainedSpec)

        ViewModel.reset()

        XCTAssertTrue(retained.isDisposed)
        XCTAssertTrue(retained.resolutionError is ViewModelError)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        binding.dispose()
    }

    func test_resetInsideBuilderDisposesDetachedValueAndDoesNotCacheIt() {
        let binding = ViewModelBinding()
        defer {
            binding.dispose()
            ViewModel.reset()
        }
        var created: RecoverableResolutionViewModel?
        let spec = ViewModelSpec<RecoverableResolutionViewModel>(
            key: "reset-inside-builder",
            throwingBuilder: {
                ViewModel.reset()
                let value = RecoverableResolutionViewModel()
                created = value
                return value
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertTrue(String(describing: error).contains("Store was disposed"))
        }
        XCTAssertEqual(created?.isDisposed, true)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }

    func test_lifecycleReentrantBindingDisposeRollsBackPendingAttachment() {
        for phase in ReentrantDisposePhase.allCases {
            let binding = ViewModelBinding()
            var created: LifecycleDisposesBindingViewModel?
            let spec = ViewModelSpec<LifecycleDisposesBindingViewModel>(
                key: "lifecycle-dispose-\(phase)",
                builder: {
                    let value = LifecycleDisposesBindingViewModel(
                        binding: binding,
                        phase: phase
                    )
                    created = value
                    return value
                }
            )

            XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
                XCTAssertTrue(
                    String(describing: error).contains("disposed during resolution")
                )
            }
            XCTAssertTrue(binding.isDisposed)
            XCTAssertEqual(created?.isDisposed, true)
            XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        }
    }

    func test_builderReentrantBindingDisposeRollsBackRetainedGeneration() {
        let binding = ViewModelBinding()
        var created: RecoverableResolutionViewModel?
        let spec = ViewModelSpec<RecoverableResolutionViewModel>(
            key: "builder-disposes-owner",
            aliveForever: true,
            builder: {
                binding.dispose()
                let value = RecoverableResolutionViewModel()
                created = value
                return value
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertTrue(
                String(describing: error).contains("disposed during resolution")
            )
        }
        XCTAssertTrue(binding.isDisposed)
        XCTAssertEqual(created?.isDisposed, true)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }

    func test_propagatedOwnerRemovedDuringOnBindDoesNotLeaveStaleRef() throws {
        var firstOwner: ViewModelBinding? = ViewModelBinding()
        let releasedOwner = WeakTestReference(firstOwner)
        let secondOwner = ViewModelBinding()
        let parentSpec = ViewModelSpec<RuntimeCycleViewModel>(key: "owner-reentry-parent") {
            RuntimeCycleViewModel()
        }
        let parent = firstOwner!.read(parentSpec)
        XCTAssertTrue(secondOwner.read(parentSpec) === parent)

        let childSpec = ViewModelSpec<OwnerRemovingOnBindViewModel> {
            OwnerRemovingOnBindViewModel(ownerToDispose: firstOwner!)
        }
        let child = try parent.viewModelBinding.readThrowing(childSpec)

        XCTAssertEqual(firstOwner?.isDisposed, true)
        firstOwner = nil
        XCTAssertNil(releasedOwner.value)
        XCTAssertFalse(parent.isDisposed)
        XCTAssertFalse(child.isDisposed)

        secondOwner.dispose()
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(child.isDisposed)
    }

    func test_childRecycledDuringPropagatedOnBindRollsBackDependencyEntry() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let parentSpec = ViewModelSpec<RuntimeCycleViewModel>(key: "recycle-hook-parent") {
            RuntimeCycleViewModel()
        }
        let parent = binding.read(parentSpec)
        var recycleFirstGeneration = true
        var firstGeneration: SelfRecyclingOnBindViewModel?
        let releasedFirstGeneration = WeakTestReference<SelfRecyclingOnBindViewModel>()
        let childSpec = ViewModelSpec<SelfRecyclingOnBindViewModel>(key: "recycle-hook-child") {
            let value = SelfRecyclingOnBindViewModel(
                binding: binding,
                shouldRecycle: recycleFirstGeneration
            )
            if recycleFirstGeneration {
                firstGeneration = value
                releasedFirstGeneration.value = value
                recycleFirstGeneration = false
            }
            return value
        }

        XCTAssertThrowsError(try parent.viewModelBinding.readThrowing(childSpec)) { error in
            XCTAssertTrue(String(describing: error).contains("disposed during resolution"))
        }
        XCTAssertEqual(firstGeneration?.isDisposed, true)
        firstGeneration = nil
        XCTAssertNil(releasedFirstGeneration.value)

        let healthy = try parent.viewModelBinding.readThrowing(childSpec)
        XCTAssertFalse(healthy.isDisposed)
        binding.dispose()
        XCTAssertTrue(parent.isDisposed)
        XCTAssertTrue(healthy.isDisposed)
    }
}
