import XCTest
@testable import AppleViewModel

@MainActor
final class StateViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_setState_fires_stateListeners_with_previous_and_current() {
        let vm = CounterStateViewModel()
        var received: [(CounterState?, CounterState)] = []
        _ = vm.listenState { prev, curr in
            received.append((prev, curr))
        }

        vm.inc()
        vm.inc()

        // Matches the Dart semantics: after each setState, `previousState`
        // holds the state that was current just before — on the very first
        // inc it is the initial state (count=0), not nil.
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].0?.count, 0)
        XCTAssertEqual(received[0].1.count, 1)
        XCTAssertEqual(received[1].0?.count, 1)
        XCTAssertEqual(received[1].1.count, 2)
    }

    func test_setState_same_state_is_skipped_when_equals_returns_true() {
        let vm = CounterStateViewModel()
        var fired = 0
        _ = vm.listenState { _, _ in fired += 1 }

        vm.setState(vm.state)  // identical state, equals returns true → skip

        XCTAssertEqual(fired, 0)
    }

    func test_listenStateSelect_only_fires_when_selected_output_differs() {
        let vm = CounterStateViewModel()
        var labelChanges = 0
        _ = vm.listenStateSelect(selector: { $0.label }) { _, _ in
            labelChanges += 1
        }

        vm.inc()  // count changes, label stays — selector unchanged, no fire
        vm.inc()  // same
        vm.setLabel("hello")  // label changes → fire

        XCTAssertEqual(labelChanges, 1)
    }

    func test_previousState_tracks_last_value() {
        let vm = CounterStateViewModel()
        XCTAssertNil(vm.previousState)
        vm.inc()
        XCTAssertEqual(vm.previousState?.count, 0)
        XCTAssertEqual(vm.state.count, 1)
        vm.inc()
        XCTAssertEqual(vm.previousState?.count, 1)
        XCTAssertEqual(vm.state.count, 2)
    }

    func test_notifyListeners_also_fires_general_listeners_after_state_change() {
        let vm = CounterStateViewModel()
        var generalFired = 0
        var stateFired = 0
        _ = vm.listen { generalFired += 1 }
        _ = vm.listenState { _, _ in stateFired += 1 }

        vm.inc()

        XCTAssertEqual(stateFired, 1)
        XCTAssertEqual(generalFired, 1, "general listener fires after state listener")
    }

    func test_instance_level_equals_overrides_default() {
        // Custom equality: only the `label` field matters.
        final class LabelOnlyStateVM: StateViewModel<CounterState> {
            init() {
                super.init(
                    state: CounterState(count: 0, label: ""),
                    equals: { $0.label == $1.label }
                )
            }
        }
        let vm = LabelOnlyStateVM()
        var fired = 0
        _ = vm.listenState { _, _ in fired += 1 }

        vm.setState(CounterState(count: 99, label: ""))  // label same → skip
        XCTAssertEqual(fired, 0)

        vm.setState(CounterState(count: 99, label: "x"))  // label changed → fire
        XCTAssertEqual(fired, 1)
    }
}
