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

/// Declare the factory at file scope so every module can reach it.
/// - `key: "app-counter"` — a single shared instance across the app.
/// - `aliveForever: true` — keep the state alive even when no view observes it.
let counterSpec = ViewModelSpec<CounterViewModel>(
    key: "app-counter",
    aliveForever: true
) {
    CounterViewModel()
}
