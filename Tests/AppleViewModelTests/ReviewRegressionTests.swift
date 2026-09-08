import Foundation
import XCTest
@testable import AppleViewModel

private protocol ReviewStateMarker {}
private final class ReviewReferenceState: ReviewStateMarker {}

@MainActor
private final class ReviewDisposalViewModel: CounterViewModel {
    var unbindAction: ((ReviewDisposalViewModel) -> Void)?

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        unbindAction?(self)
    }
}

@MainActor
final class StateEqualityRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_defaultEqualityDoesNotBridgeIntegers() {
        assertDefaultValueNotifies(1)
    }

    func test_defaultEqualityDoesNotBridgeBooleans() {
        assertDefaultValueNotifies(true)
    }

    func test_defaultEqualityTreatsOptionalsAsValues() {
        assertDefaultValueNotifies(Optional<Int>.none)
        assertDefaultValueNotifies(Optional(1))
        assertDefaultValueNotifies(Optional(ReviewReferenceState()))
    }

    func test_defaultEqualityNotifiesForStringsAndStructs() {
        assertDefaultValueNotifies("same")
        assertDefaultValueNotifies(CounterState(count: 1, label: "same"))
    }

    func test_defaultEqualityPreservesReferenceIdentity() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let initial = ReviewReferenceState()
        let spec = ViewModelSpec<StateViewModel<ReviewReferenceState>> {
            StateViewModel(state: initial)
        }
        let viewModel = binding.read(spec)
        var calls = 0
        _ = viewModel.listen { calls += 1 }

        viewModel.setState(initial)
        XCTAssertEqual(calls, 0)

        let replacement = ReviewReferenceState()
        viewModel.setState(replacement)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(viewModel.state === replacement)
        XCTAssertTrue(viewModel.previousState === initial)
    }

    func test_defaultEqualityUsesDynamicTypeForErasedState() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let initial = ReviewReferenceState()
        let spec = ViewModelSpec<StateViewModel<Any>> {
            StateViewModel<Any>(state: initial)
        }
        let viewModel = binding.read(spec)
        var calls = 0
        _ = viewModel.listen { calls += 1 }

        viewModel.setState(initial)
        XCTAssertEqual(calls, 0)
        viewModel.setState(1)
        viewModel.setState(1)
        XCTAssertEqual(calls, 2)
    }

    func test_defaultEqualityPreservesProtocolWrappedReferenceIdentity() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let initial = ReviewReferenceState()
        let spec = ViewModelSpec<StateViewModel<any ReviewStateMarker>> {
            StateViewModel<any ReviewStateMarker>(state: initial)
        }
        let viewModel = binding.read(spec)
        var calls = 0
        _ = viewModel.listen { calls += 1 }

        viewModel.setState(initial)
        XCTAssertEqual(calls, 0)
        viewModel.setState(ReviewReferenceState())
        XCTAssertEqual(calls, 1)
    }

    func test_explicitEqualityCanDeduplicateValueState() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel(state: 1, equals: { $0 == $1 })
        }
        let viewModel = binding.read(spec)
        var calls = 0
        _ = viewModel.listen { calls += 1 }

        viewModel.setState(1)
        XCTAssertEqual(calls, 0)
        viewModel.setState(2)
        XCTAssertEqual(calls, 1)
    }

    func test_localEqualityStillTakesPriorityOverGlobalEquality() {
        ViewModel.initialize(config: ViewModelConfig(equals: { _, _ in true }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let globalSpec = ViewModelSpec<StateViewModel<Int>>(key: "global-equality") {
            StateViewModel(state: 1)
        }
        let localSpec = ViewModelSpec<StateViewModel<Int>>(key: "local-equality") {
            StateViewModel(state: 1, equals: { _, _ in false })
        }
        let global = binding.read(globalSpec)
        let local = binding.read(localSpec)
        var globalCalls = 0
        var localCalls = 0
        _ = global.listen { globalCalls += 1 }
        _ = local.listen { localCalls += 1 }

        global.setState(2)
        local.setState(1)

        XCTAssertEqual(globalCalls, 0)
        XCTAssertEqual(global.state, 1)
        XCTAssertEqual(localCalls, 1)
    }

    private func assertDefaultValueNotifies<State>(
        _ value: State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<State>> {
            StateViewModel(state: value)
        }
        let viewModel = binding.read(spec)
        var stateCalls = 0
        var generalCalls = 0
        _ = viewModel.listenState { _, _ in stateCalls += 1 }
        _ = viewModel.listen { generalCalls += 1 }

        viewModel.setState(value)

        XCTAssertEqual(stateCalls, 1, file: file, line: line)
        XCTAssertEqual(generalCalls, 1, file: file, line: line)
    }
}

@MainActor
final class DisposalRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_forceRecycleFromOnUnbindRunsLifecycleOnce() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ReviewDisposalViewModel> {
            ReviewDisposalViewModel()
        }
        let viewModel = binding.read(spec)
        var didReenter = false
        var nestedRecycleSucceeded = false
        viewModel.unbindAction = { value in
            // Bound the reproduction so the old implementation fails an
            // assertion rather than overflowing the test process's stack.
            guard !didReenter else { return }
            didReenter = true
            nestedRecycleSucceeded = InstanceManager.shared.recycle(value)
        }

        binding.recycle(viewModel)

        XCTAssertTrue(nestedRecycleSucceeded)
        XCTAssertEqual(viewModel.onUnbindCalls, 1)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
        XCTAssertTrue(viewModel.isDisposed)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }

    func test_forceRecycleWithMultipleOwnersUnbindsEachOwnerOnce() {
        let first = ViewModelBinding()
        let second = ViewModelBinding()
        defer {
            first.dispose()
            second.dispose()
        }
        let spec = ViewModelSpec<ReviewDisposalViewModel>(key: "shared-recycle") {
            ReviewDisposalViewModel()
        }
        let viewModel = first.read(spec)
        XCTAssertTrue(second.read(spec) === viewModel)
        var didReenter = false
        viewModel.unbindAction = { value in
            guard !didReenter else { return }
            didReenter = true
            _ = InstanceManager.shared.recycle(value)
        }

        first.recycle(viewModel)

        XCTAssertEqual(viewModel.onBindCalls, 2)
        XCTAssertEqual(viewModel.onUnbindCalls, 2)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
    }

    func test_forceRecycleRejectsReattachmentDuringOnUnbind() {
        let owner = ViewModelBinding()
        let lateOwner = ViewModelBinding()
        defer {
            owner.dispose()
            lateOwner.dispose()
        }
        let spec = ViewModelSpec<ReviewDisposalViewModel>(key: "disposing-generation") {
            ReviewDisposalViewModel()
        }
        let viewModel = owner.read(spec)
        var attempted = false
        var attachmentError: Error?
        viewModel.unbindAction = { _ in
            guard !attempted else { return }
            attempted = true
            do {
                _ = try lateOwner.readThrowing(spec)
            } catch {
                attachmentError = error
            }
        }

        owner.recycle(viewModel)

        XCTAssertTrue(attempted)
        XCTAssertNotNil(attachmentError)
        XCTAssertEqual(viewModel.onBindCalls, 1)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
        let replacement = lateOwner.read(spec)
        XCTAssertFalse(replacement === viewModel)
        XCTAssertFalse(replacement.isDisposed)
    }

    func test_handleDisposalListenerCannotReenterDisposal() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ReviewDisposalViewModel>(key: "handle-reentry") {
            ReviewDisposalViewModel()
        }
        let viewModel = binding.read(spec)
        let handle = try InstanceManager.shared.getHandle(
            ReviewDisposalViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "handle-reentry"))
        )
        var calls = 0
        _ = handle.addListener { current in
            calls += 1
            if calls == 1 {
                current.unbindAll(force: true)
            }
        }

        binding.recycle(viewModel)

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
        XCTAssertTrue(handle.isDisposed)
        XCTAssertNil(handle.value)
        XCTAssertThrowsError(try handle.requireInstance())
    }

    func test_normalLastUnbindCanStillAcquireANewOwner() {
        let owner = ViewModelBinding()
        let replacementOwner = ViewModelBinding()
        defer {
            owner.dispose()
            replacementOwner.dispose()
        }
        let spec = ViewModelSpec<ReviewDisposalViewModel>(key: "normal-unbind") {
            ReviewDisposalViewModel()
        }
        let viewModel = owner.read(spec)
        viewModel.unbindAction = { value in
            value.unbindAction = nil
            XCTAssertTrue(replacementOwner.read(spec) === value)
        }

        owner.dispose()

        XCTAssertFalse(viewModel.isDisposed)
        XCTAssertEqual(viewModel.onBindCalls, 2)
        XCTAssertEqual(viewModel.onUnbindCalls, 1)
        replacementOwner.dispose()
        XCTAssertTrue(viewModel.isDisposed)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
    }

    func test_aliveForeverStillSurvivesZeroOwnersUntilExplicitRecycle() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ReviewDisposalViewModel>(
            key: "retained-reentry", aliveForever: true
        ) {
            ReviewDisposalViewModel()
        }
        let viewModel = binding.read(spec)

        binding.dispose()
        XCTAssertFalse(viewModel.isDisposed)
        XCTAssertEqual(viewModel.onUnbindCalls, 1)
        XCTAssertTrue(InstanceManager.shared.recycle(viewModel))
        XCTAssertTrue(viewModel.isDisposed)
        XCTAssertEqual(viewModel.onDisposeCalls, 1)
    }

    func test_emptyStoreIsReleasedAfterLastOwnerDisposes() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        _ = binding.read(spec)
        weak var releasedStore = InstanceManager.shared.store(for: CounterViewModel.self)
        XCTAssertNotNil(releasedStore)

        binding.dispose()

        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        XCTAssertNil(releasedStore)
    }

    func test_retainedStoreIsReleasedAfterRuntimeReset() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(
            key: "reset-store", aliveForever: true
        ) { CounterViewModel() }
        _ = binding.read(spec)
        weak var releasedStore = InstanceManager.shared.store(for: CounterViewModel.self)
        binding.dispose()
        XCTAssertNotNil(releasedStore)

        TestEnv.reset()

        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        XCTAssertNil(releasedStore)
    }
}
