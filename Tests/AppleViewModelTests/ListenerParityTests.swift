import Foundation
import XCTest
@testable import AppleViewModel

private struct ListenerFailure: Error {}
private struct ErrorHandlerFailure: Error {}

private final class ErrorTypeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ type: ErrorType) {
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .listener: values.append("listener")
        case .lifecycle: values.append("lifecycle")
        case .dispose: values.append("dispose")
        case .pauseResume: values.append("pauseResume")
        }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
private final class ListenerParityViewModel: ViewModel {}

private struct ListenerParityState: Equatable {
    var count: Int
    var label: String
}

@MainActor
private final class ListenerParityStateViewModel: StateViewModel<ListenerParityState> {
    init() {
        super.init(
            state: ListenerParityState(count: 0, label: ""),
            equals: { $0 == $1 }
        )
    }

    func set(count: Int? = nil, label: String? = nil) {
        setState(ListenerParityState(
            count: count ?? state.count,
            label: label ?? state.label
        ))
    }
}

@MainActor
final class ListenerParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_listenerSnapshotUsesRegistrationOrderAndLiveTokens() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityViewModel> {
            ListenerParityViewModel()
        }
        let viewModel = binding.read(spec)
        var events: [String] = []
        var removeSecond: () -> Void = {}
        var didAddListener = false

        _ = viewModel.listen {
            events.append("first")
            removeSecond()
            if !didAddListener {
                didAddListener = true
                _ = viewModel.listen { events.append("added") }
            }
        }
        removeSecond = viewModel.listen { events.append("second") }

        viewModel.notifyListeners()
        XCTAssertEqual(events, ["first"])

        viewModel.notifyListeners()
        XCTAssertEqual(events, ["first", "first", "added"])
    }

    func test_listenerFailureAndFailingErrorHandlerDoNotSkipLaterListeners() {
        let recorder = ErrorTypeRecorder()
        ViewModel.initialize(config: ViewModelConfig(onError: { _, type in
            recorder.append(type)
            throw ErrorHandlerFailure()
        }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityViewModel> {
            ListenerParityViewModel()
        }
        let viewModel = binding.read(spec)
        var survivorCalls = 0
        _ = viewModel.listen { throw ListenerFailure() }
        _ = viewModel.listen { survivorCalls += 1 }

        viewModel.notifyListeners()

        XCTAssertEqual(recorder.snapshot, ["listener"])
        XCTAssertEqual(survivorCalls, 1)
    }

    func test_throwingUpdateDoesNotNotify() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityViewModel> {
            ListenerParityViewModel()
        }
        let viewModel = binding.read(spec)
        var calls = 0
        _ = viewModel.listen { calls += 1 }

        XCTAssertThrowsError(try viewModel.update { throw ListenerFailure() })
        XCTAssertEqual(calls, 0)
    }

    func test_reentrantStateUpdatesKeepEachTransitionPairStable() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityStateViewModel> {
            ListenerParityStateViewModel()
        }
        let viewModel = binding.read(spec)
        var transitions: [(Int, Int)] = []
        var observerTransitions: [(Int, Int)] = []
        _ = viewModel.listenState { previous, current in
            transitions.append((previous?.count ?? -1, current.count))
            if current.count == 1 {
                viewModel.set(count: 2)
            }
        }
        _ = viewModel.listenState { previous, current in
            observerTransitions.append((previous?.count ?? -1, current.count))
        }

        viewModel.set(count: 1)

        XCTAssertEqual(transitions.map(\.0), [0, 1])
        XCTAssertEqual(transitions.map(\.1), [1, 2])
        // The nested transition completes first. The second observer must then
        // receive the frozen outer event rather than mutable global state.
        XCTAssertEqual(observerTransitions.map(\.0), [1, 0])
        XCTAssertEqual(observerTransitions.map(\.1), [2, 1])
        XCTAssertEqual(viewModel.previousState?.count, 1)
        XCTAssertEqual(viewModel.state.count, 2)
    }

    func test_stateListenerSnapshotAndErrorsMatchGeneralListenerSemantics() {
        let recorder = ErrorTypeRecorder()
        ViewModel.initialize(config: ViewModelConfig(onError: { _, type in
            recorder.append(type)
        }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityStateViewModel> {
            ListenerParityStateViewModel()
        }
        let viewModel = binding.read(spec)
        var events: [String] = []
        var removeSecond: () -> Void = {}

        _ = viewModel.listenState { _, _ in
            events.append("first")
            removeSecond()
            throw ListenerFailure()
        }
        removeSecond = viewModel.listenState { _, _ in events.append("second") }
        _ = viewModel.listen { events.append("general") }

        viewModel.set(count: 1)

        XCTAssertEqual(events, ["first", "general"])
        XCTAssertEqual(recorder.snapshot, ["listener"])
    }

    func test_selectorEqualityUsesLocalThenGlobalThenEquatable() {
        ViewModel.initialize(config: ViewModelConfig(equals: { previous, current in
            guard previous is String, current is String else { return false }
            return true
        }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<ListenerParityStateViewModel> {
            ListenerParityStateViewModel()
        }
        let viewModel = binding.read(spec)
        var globalFallbackCalls = 0
        var localOverrideCalls = 0

        _ = viewModel.listenStateSelect(
            selector: { $0.label },
            onChanged: { _, _ in globalFallbackCalls += 1 }
        )
        _ = viewModel.listenStateSelect(
            selector: { $0.label },
            equals: { _, _ in false },
            onChanged: { _, _ in localOverrideCalls += 1 }
        )

        viewModel.set(label: "next")

        XCTAssertEqual(globalFallbackCalls, 0)
        XCTAssertEqual(localOverrideCalls, 1)
    }
}
