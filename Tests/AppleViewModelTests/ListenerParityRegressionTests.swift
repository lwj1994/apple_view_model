import Foundation
import XCTest
@testable import AppleViewModel

private enum ListenerRegressionFailure: Error {
    case callback
    case reporter
}

private final class ListenerRegressionErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// Deliberately does not conform to Equatable: callers compare its identifier.
private final class ListenerRegressionReference {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

private struct ListenerRegressionSelectionState {
    let selected: ListenerRegressionReference
}

@MainActor
final class ListenerParityRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_nonEquatableSelectionUsesExplicitEqualityForDirectAndBindingListeners() {
        ViewModel.initialize(config: ViewModelConfig(equals: { _, _ in true }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<ListenerRegressionSelectionState>> {
            StateViewModel(
                state: ListenerRegressionSelectionState(selected: ListenerRegressionReference(id: 0)),
                equals: { _, _ in false }
            )
        }
        let viewModel = binding.read(spec)
        var direct: [(Int, Int)] = []
        var bound: [(Int, Int)] = []
        let cancelDirect = viewModel.listenStateSelect(
            selector: { $0.selected },
            equals: { $0.id == $1.id },
            onChanged: { direct.append(($0.id, $1.id)) }
        )
        binding.listenStateSelect(
            spec,
            selector: { $0.selected },
            equals: { $0.id == $1.id },
            onChanged: { bound.append(($0.id, $1.id)) }
        )
        XCTAssertTrue(direct.isEmpty)
        XCTAssertTrue(bound.isEmpty)

        viewModel.setState(ListenerRegressionSelectionState(selected: ListenerRegressionReference(id: 0)))
        viewModel.setState(ListenerRegressionSelectionState(selected: ListenerRegressionReference(id: 1)))
        cancelDirect()
        cancelDirect()
        viewModel.setState(ListenerRegressionSelectionState(selected: ListenerRegressionReference(id: 2)))

        XCTAssertEqual(direct.map(\.0), [0])
        XCTAssertEqual(direct.map(\.1), [1])
        XCTAssertEqual(bound.map(\.0), [0, 1])
        XCTAssertEqual(bound.map(\.1), [1, 2])
    }

    func test_duplicateGeneralAndStateRegistrationsHaveIndependentCancellation() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel(state: 0, equals: { $0 == $1 })
        }
        let viewModel = binding.read(spec)
        var generalCalls = 0
        var stateCalls = 0
        let generalCallback: () -> Void = { generalCalls += 1 }
        let stateCallback: (Int, Int) -> Void = { _, _ in stateCalls += 1 }
        let cancelFirstGeneral = viewModel.listen(onChanged: generalCallback)
        let cancelSecondGeneral = viewModel.listen(onChanged: generalCallback)
        let cancelFirstState = viewModel.listenState(onChanged: stateCallback)
        let cancelSecondState = viewModel.listenState(onChanged: stateCallback)

        viewModel.setState(1)
        XCTAssertEqual(generalCalls, 2)
        XCTAssertEqual(stateCalls, 2)

        cancelFirstGeneral()
        cancelFirstGeneral()
        cancelFirstState()
        cancelFirstState()
        viewModel.setState(2)
        XCTAssertEqual(generalCalls, 3)
        XCTAssertEqual(stateCalls, 3)
        XCTAssertTrue(viewModel.hasListeners)

        cancelSecondGeneral()
        cancelSecondState()
        viewModel.setState(3)
        XCTAssertEqual(generalCalls, 3)
        XCTAssertEqual(stateCalls, 3)
        XCTAssertFalse(viewModel.hasListeners)
    }

    func test_generalListenerMembershipSurvivesReentrantMutationAndErrors() {
        let errors = ListenerRegressionErrorCounter()
        ViewModel.initialize(config: ViewModelConfig(onError: { _, _ in
            errors.record()
            throw ListenerRegressionFailure.reporter
        }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ViewModel> { ViewModel() }
        let viewModel = binding.read(spec)
        var events: [String] = []
        var cancelSecond: () -> Void = {}
        var isNested = false

        _ = viewModel.listen {
            events.append(isNested ? "first nested" : "first outer")
            cancelSecond()
            if !isNested {
                isNested = true
                _ = viewModel.listen { events.append("added") }
                viewModel.notifyListeners()
            }
            throw ListenerRegressionFailure.callback
        }
        cancelSecond = viewModel.listen { events.append("removed") }
        _ = viewModel.listen { events.append("survivor") }

        viewModel.notifyListeners()

        XCTAssertEqual(events, ["first outer", "first nested", "survivor", "added", "survivor"])
        XCTAssertEqual(errors.count, 2)
    }

    func test_stateListenerMembershipSurvivesQueuedMutationAndErrors() {
        let errors = ListenerRegressionErrorCounter()
        ViewModel.initialize(config: ViewModelConfig(onError: { _, _ in
            errors.record()
            throw ListenerRegressionFailure.reporter
        }))
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel(state: 0, equals: { $0 == $1 })
        }
        let viewModel = binding.watch(spec)
        var events: [String] = []
        var cancelSecond: () -> Void = {}
        var refreshes = 0
        binding.refresh = { refreshes += 1 }

        _ = viewModel.listenState { previous, current in
            events.append("first \(previous)->\(current)")
            cancelSecond()
            if current == 1 {
                _ = viewModel.listenState { previous, current in
                    events.append("added \(previous)->\(current)")
                }
                viewModel.setState(2)
            }
            throw ListenerRegressionFailure.callback
        }
        cancelSecond = viewModel.listenState { _, _ in events.append("removed") }
        _ = viewModel.listenState { previous, current in
            events.append("survivor \(previous)->\(current)")
        }
        _ = viewModel.listen { events.append("general \(viewModel.state)") }

        viewModel.setState(1)

        XCTAssertEqual(events, [
            "first 0->1", "survivor 0->1", "general 2",
            "first 1->2", "survivor 1->2", "added 1->2", "general 2"
        ])
        XCTAssertEqual(errors.count, 2)
        XCTAssertEqual(refreshes, 1)
    }

    func test_fifoReleasesConsumedReferenceStatesBeforeTheCascadeEnds() {
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<ListenerRegressionReference>> {
            StateViewModel(state: ListenerRegressionReference(id: 0))
        }
        let viewModel = binding.watch(spec)
        weak var retiredState: ListenerRegressionReference?
        var releasedDuringDrain = false
        var transitions: [Int] = []
        var refreshes = 0
        binding.refresh = { refreshes += 1 }

        _ = viewModel.listenState { _, current in
            transitions.append(current.id)
            if current.id == 2 { retiredState = current }
            if current.id == 5 {
                // State 2 is no longer initialState, state, previousState, or
                // part of the current event. The drained queue must release it.
                releasedDuringDrain = retiredState == nil
            }
            if current.id == 1 {
                viewModel.setState(ListenerRegressionReference(id: 2))
                viewModel.setState(ListenerRegressionReference(id: 3))
            } else if current.id < 63 {
                viewModel.setState(ListenerRegressionReference(id: current.id + 2))
            }
        }

        viewModel.setState(ListenerRegressionReference(id: 1))

        XCTAssertEqual(transitions, Array(1...64))
        XCTAssertTrue(releasedDuringDrain, "Consumed events must not retain all earlier states until the cascade ends")
        XCTAssertEqual(viewModel.state.id, 64)
        XCTAssertEqual(viewModel.previousState?.id, 63)
        XCTAssertEqual(refreshes, 1)
    }

    func test_disposalDuringAQueuedEventDropsRemainingAndNewlyQueuedEvents() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel(state: 0, equals: { $0 == $1 })
        }
        let viewModel = binding.read(spec)
        var events: [String] = []
        _ = viewModel.listenState { _, current in
            events.append("first \(current)")
            if current == 1 {
                viewModel.setState(2)
                viewModel.setState(3)
            } else if current == 2 {
                viewModel.setState(4)
                binding.recycle(viewModel)
            }
        }
        _ = viewModel.listenState { _, current in events.append("second \(current)") }
        _ = viewModel.listen { events.append("general \(viewModel.state)") }

        viewModel.setState(1)
        viewModel.setState(5)
        viewModel.notifyListeners()

        XCTAssertEqual(events, ["first 1", "second 1", "general 3", "first 2"])
        XCTAssertEqual(viewModel.state, 4)
        XCTAssertTrue(viewModel.isDisposed)
        XCTAssertFalse(viewModel.hasListeners)
    }
}
