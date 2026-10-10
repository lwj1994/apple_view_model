import XCTest
@testable import AppleViewModel

@MainActor
private final class StateTransitionParentViewModel: ViewModel {
    private let childSpec: ViewModelSpec<StateViewModel<Int>>

    init(childSpec: ViewModelSpec<StateViewModel<Int>>) {
        self.childSpec = childSpec
        super.init()
    }

    var child: StateViewModel<Int> { viewModelBinding.watch(childSpec) }
}

@MainActor
final class StateListenerTransitionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_bindingStateListenerReceivesNonOptionalPreviousState() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterStateViewModel> { CounterStateViewModel() }
        let viewModel = binding.read(spec)
        var transitions: [(CounterState, CounterState)] = []
        let callback: (CounterState, CounterState) -> Void = { previous, current in
            transitions.append((previous, current))
        }

        binding.listenState(spec, onChanged: callback)
        XCTAssertTrue(transitions.isEmpty, "Subscribing does not invent an initial transition")

        viewModel.inc()
        viewModel.inc()

        XCTAssertEqual(transitions.map { $0.0.count }, [0, 1])
        XCTAssertEqual(transitions.map { $0.1.count }, [1, 2])
    }

    func test_directAndBindingSelectorsReceiveNonOptionalSelectedValues() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterStateViewModel> { CounterStateViewModel() }
        let viewModel = binding.read(spec)
        var direct: [(String, String)] = []
        var bound: [(String, String)] = []
        let directCallback: (String, String) -> Void = { direct.append(($0, $1)) }
        let bindingCallback: (String, String) -> Void = { bound.append(($0, $1)) }
        _ = viewModel.listenStateSelect(selector: { $0.label }, onChanged: directCallback)
        binding.listenStateSelect(spec, selector: { $0.label }, onChanged: bindingCallback)

        viewModel.inc()
        XCTAssertTrue(direct.isEmpty)
        XCTAssertTrue(bound.isEmpty)

        viewModel.setLabel("first")
        viewModel.inc()
        viewModel.setLabel("second")

        XCTAssertEqual(direct.map(\.0), ["", "first"])
        XCTAssertEqual(direct.map(\.1), ["first", "second"])
        XCTAssertEqual(bound.map(\.0), direct.map(\.0))
        XCTAssertEqual(bound.map(\.1), direct.map(\.1))
    }

    func test_optionalStateKeepsNilTransitionsWithoutWrappingCallbackValues() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int?>> {
            StateViewModel<Int?>(state: nil, equals: { $0 == $1 })
        }
        let viewModel = binding.read(spec)
        var direct: [(Int?, Int?)] = []
        var bound: [(Int?, Int?)] = []
        let directCallback: (Int?, Int?) -> Void = { direct.append(($0, $1)) }
        let bindingCallback: (Int?, Int?) -> Void = { bound.append(($0, $1)) }
        _ = viewModel.listenState(onChanged: directCallback)
        binding.listenState(spec, onChanged: bindingCallback)

        // The property still needs an outer Optional to represent no transition.
        if case .none = viewModel.previousState {} else {
            XCTFail("previousState should initially have no transition")
        }
        viewModel.setState(1)
        if case .some(.none) = viewModel.previousState {} else {
            XCTFail("The first previous state should be the real nil initial value")
        }
        viewModel.setState(nil)
        if case .some(.some(1)) = viewModel.previousState {} else {
            XCTFail("previousState should preserve the previous non-nil value")
        }
        viewModel.setState(nil)

        XCTAssertEqual(direct.map(\.0), [nil, 1])
        XCTAssertEqual(direct.map(\.1), [1, nil])
        XCTAssertEqual(bound.map(\.0), direct.map(\.0))
        XCTAssertEqual(bound.map(\.1), direct.map(\.1))
    }

    func test_optionalSelectorCanTransitionToAndFromNil() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterStateViewModel> { CounterStateViewModel() }
        let viewModel = binding.read(spec)
        let selector: (CounterState) -> String? = { $0.label.isEmpty ? nil : $0.label }
        var direct: [(String?, String?)] = []
        var bound: [(String?, String?)] = []
        let directCallback: (String?, String?) -> Void = { direct.append(($0, $1)) }
        let bindingCallback: (String?, String?) -> Void = { bound.append(($0, $1)) }
        _ = viewModel.listenStateSelect(selector: selector, onChanged: directCallback)
        binding.listenStateSelect(spec, selector: selector, onChanged: bindingCallback)

        viewModel.inc()
        viewModel.setLabel("selected")
        viewModel.inc()
        viewModel.setLabel("")

        XCTAssertEqual(direct.map(\.0), [nil, "selected"])
        XCTAssertEqual(direct.map(\.1), ["selected", nil])
        XCTAssertEqual(bound.map(\.0), direct.map(\.0))
        XCTAssertEqual(bound.map(\.1), direct.map(\.1))
    }

    func test_nestedStateAndSelectorCallbacksDrainInFIFOOrderWithOneRootRefresh() {
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel<Int>(state: 0, equals: { $0 == $1 })
        }
        let viewModel = binding.watch(spec)
        var events: [String] = []
        var refreshes = 0
        binding.refresh = { refreshes += 1 }
        _ = viewModel.listenState { previous, current in
            events.append("state \(previous)->\(current)")
            if current == 1 { viewModel.setState(2) }
        }
        binding.listenStateSelect(spec, selector: { $0 }) { previous, current in
            events.append("selector \(previous)->\(current)")
        }
        binding.listenState(spec) { previous, current in
            events.append("bound \(previous)->\(current)")
        }
        _ = viewModel.listen { events.append("general \(viewModel.state)") }

        viewModel.setState(1)

        XCTAssertEqual(events, [
            "state 0->1",
            "selector 0->1",
            "bound 0->1",
            "general 2",
            "state 1->2",
            "selector 1->2",
            "bound 1->2",
            "general 2"
        ])
        XCTAssertEqual(refreshes, 1, "One synchronous transition drain refreshes a root once")
        XCTAssertEqual(viewModel.state, 2)
        XCTAssertEqual(viewModel.previousState, 1)
    }

    func test_nestedChildTransitionsNotifyParentForEveryEventButRefreshRootOnce() {
        let binding = HostedViewModelBinding()
        defer { binding.dispose() }
        let childSpec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel<Int>(state: 0, equals: { $0 == $1 })
        }
        let parentSpec = ViewModelSpec<StateTransitionParentViewModel> {
            StateTransitionParentViewModel(childSpec: childSpec)
        }
        let parent = binding.watch(parentSpec)
        let child = parent.child
        var parentStates: [Int] = []
        var refreshes = 0
        binding.refresh = { refreshes += 1 }
        _ = parent.listen { parentStates.append(child.state) }
        _ = child.listen {
            if child.state == 1 { child.setState(2) }
        }

        child.setState(1)

        XCTAssertEqual(parentStates, [1, 2], "Dependency forwarding must preserve both general notifications")
        XCTAssertEqual(refreshes, 1, "Only the root's UI refresh is deduplicated")
        XCTAssertEqual(child.state, 2)
        XCTAssertEqual(child.previousState, 1)
    }

    func test_disposalDuringCallbackStopsCurrentTransitionAndDiscardsQueuedTransitions() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<StateViewModel<Int>> {
            StateViewModel<Int>(state: 0, equals: { $0 == $1 })
        }
        let viewModel = binding.read(spec)
        var events: [String] = []
        _ = viewModel.listenState { previous, current in
            events.append("first \(previous)->\(current)")
            if current == 1 {
                viewModel.setState(2)
                binding.recycle(viewModel)
            }
        }
        _ = viewModel.listenState { _, _ in events.append("second") }
        binding.listenStateSelect(spec, selector: { $0 }) { _, _ in
            events.append("selector")
        }
        _ = viewModel.listen { events.append("general") }

        viewModel.setState(1)

        XCTAssertEqual(events, ["first 0->1"])
        XCTAssertTrue(viewModel.isDisposed)
        XCTAssertEqual(viewModel.state, 2, "Nested state is committed before its event is queued")
        XCTAssertFalse(binding.read(spec) === viewModel)
    }
}
