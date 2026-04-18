import XCTest
@testable import AppleViewModel

/// Shared fixture. Each test class resets global state in `setUp` so specs and
/// cached instances don't bleed between test cases.
///
/// Tests run on the main queue by default, so `MainActor.assumeIsolated` is a
/// safe bridge from the nonisolated `XCTestCase.setUp()` back into our
/// `@MainActor` world.
enum TestEnv {
    static func reset() {
        MainActor.assumeIsolated {
            InstanceManager.shared.debugReset()
            ViewModel.debugReset()
        }
    }
}

/// Smallest possible `ViewModel` subclass — counts lifecycle calls and
/// increments a counter on demand.
@MainActor
class CounterViewModel: ViewModel {
    var count: Int = 0
    var onCreateCalls: Int = 0
    var onBindCalls: Int = 0
    var onUnbindCalls: Int = 0
    var onDisposeCalls: Int = 0

    func increment() {
        update { count += 1 }
    }

    override func onCreate(_ arg: InstanceArg) {
        super.onCreate(arg)
        onCreateCalls += 1
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        onBindCalls += 1
    }

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        onUnbindCalls += 1
    }

    override func onDispose(_ arg: InstanceArg) {
        onDisposeCalls += 1
        super.onDispose(arg)
    }
}

/// Value-typed state used by `StateViewModel` test fixtures.
struct CounterState: Equatable {
    var count: Int
    var label: String
}

@MainActor
final class CounterStateViewModel: StateViewModel<CounterState> {
    init() {
        super.init(state: CounterState(count: 0, label: ""), equals: { $0 == $1 })
    }

    func inc() {
        setState(CounterState(count: state.count + 1, label: state.label))
    }

    func setLabel(_ text: String) {
        setState(CounterState(count: state.count, label: text))
    }
}
