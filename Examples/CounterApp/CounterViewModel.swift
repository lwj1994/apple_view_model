import AppleViewModel

/// Value-typed state so `listenStateSelect` and diff comparisons are cheap.
struct CounterState: Equatable {
    var count: Int = 0
    var label: String = ""
}

/// Subclassing `StateViewModel` hands you:
/// - `state` / `previousState` read-only properties,
/// - `setState(_:)` for writes,
/// - `listen` / `listenState` / `listenStateSelect` for subscriptions,
/// - `viewModelBinding` for reaching other ViewModels.
@MainActor
final class CounterViewModel: StateViewModel<CounterState> {
    init() {
        super.init(state: CounterState())
    }

    func increment() {
        setState(CounterState(count: state.count + 1, label: state.label))
    }

    func updateLabel(_ text: String) {
        setState(CounterState(count: state.count, label: text))
    }
}

/// Declare a stable spec at file scope and let the resolving binding own the
/// instance by default. Add a key or `aliveForever` only when cross-binding
/// sharing or retention is an explicit requirement.
let counterSpec = ViewModelSpec<CounterViewModel> {
    CounterViewModel()
}
