import Foundation

/// ViewModel that owns an immutable state object of type `State`.
///
/// `setState(_:)` is the only mutation entry point. On each accepted update the
/// framework fires:
/// 1. every `listenState` / `listenStateSelect` callback with `(previous, current)`,
/// 2. every general `listen` callback registered on the base `ViewModel`.
///
/// State equality resolution order: instance-level `equals` → global
/// `ViewModelConfig.equals` → reference-identity (`===`) for class types. For value
/// types without an explicit `equals`, every `setState` call is considered a change.
///
/// Corresponds to the Dart `StateViewModel<T>`.
@MainActor
open class StateViewModel<State>: ViewModel {
    public private(set) var state: State
    /// The last replaced state, or `nil` before the first transition. Listener
    /// callbacks already have a previous value and therefore use `State` itself.
    public private(set) var previousState: State?
    public let initialState: State

    private struct StateListenerEntry {
        let id: UUID
        let callback: (State, State) throws -> Void
    }

    private let equalsFn: (State, State) -> Bool
    private var stateListeners: [StateListenerEntry] = []
    private var pendingStateEvents: [(previous: State, current: State)] = []
    private var isDispatchingStateEvents = false

    public init(state: State, equals: ((State, State) -> Bool)? = nil) {
        self.state = state
        self.initialState = state
        if let equals {
            self.equalsFn = equals
        } else {
            self.equalsFn = { prev, next in
                if let globalEquals = ViewModel.config.equals {
                    return globalEquals(prev, next)
                }
                // Check dynamic types before casting: AnyObject also boxes value
                // types (including Optional), and shared bridge objects can make
                // unrelated value states appear reference-identical. Erasing to
                // Any preserves the dynamic type of class-backed existentials.
                guard Swift.type(of: prev as Any) is AnyClass,
                      Swift.type(of: next as Any) is AnyClass else {
                    return false
                }
                return (prev as AnyObject) === (next as AnyObject)
            }
        }
        super.init()
    }

    /// Subscribe to actual transitions; callback receives `(previous, current)`.
    /// Registration does not emit an initial event. Both values have type
    /// `State`, which permits `nil` only when `State` itself is optional.
    @discardableResult
    public func listenState(
        onChanged: @escaping (State, State) throws -> Void
    ) -> () -> Void {
        _listenStateTransition(onChanged: onChanged)
    }

    /// Internal raw state transition stream used by selector hosts.
    ///
    /// Keeping the transition raw lets long-lived SwiftUI `@StateObject` hosts
    /// apply their latest selector configuration without replacing the
    /// ViewModel subscription on every parent render.
    @discardableResult
    func _listenStateTransition(
        onChanged: @escaping (State, State) throws -> Void
    ) -> () -> Void {
        let id = UUID()
        stateListeners.append(StateListenerEntry(
            id: id,
            callback: onChanged
        ))
        return { [weak self] in
            self?.stateListeners.removeAll { $0.id == id }
        }
    }

    /// Subscribe to the output of a selector. Equality resolution is local
    /// `equals` → global `ViewModelConfig.equals` → Swift `Equatable`.
    /// Both callback values have type `R`, without an extra Optional wrapper.
    @discardableResult
    public func listenStateSelect<R: Equatable>(
        selector: @escaping (State) -> R,
        equals: ((R, R) -> Bool)? = nil,
        onChanged: @escaping (R, R) throws -> Void
    ) -> () -> Void {
        let globalEquals = ViewModel.config.equals
        let effectiveEquals: (R, R) -> Bool = equals ?? { previous, current in
            if let globalEquals {
                return globalEquals(previous, current)
            }
            return previous == current
        }
        let wrapped: (State, State) throws -> Void = { prevState, currState in
            let prevSel = selector(prevState)
            let currSel = selector(currState)
            if !effectiveEquals(prevSel, currSel) {
                try onChanged(prevSel, currSel)
            }
        }
        return _listenStateTransition(onChanged: wrapped)
    }

    /// The single mutation entry point. Emits notifications when the incoming
    /// state differs from the current one according to `equalsFn`.
    public func setState(_ newState: State) {
        if isDisposed {
            viewModelLog("\(type(of: self)): setState after Disposed")
            return
        }
        if equalsFn(state, newState) { return }
        let previous = state
        previousState = previous
        state = newState
        pendingStateEvents.append((previous, newState))
        guard !isDispatchingStateEvents else { return }
        isDispatchingStateEvents = true
        defer {
            isDispatchingStateEvents = false
            pendingStateEvents.removeAll(keepingCapacity: true)
        }

        // Reentrant setState changes the value immediately, but its event waits
        // until every remaining listener has received the current transition.
        // Indexing avoids repeatedly shifting an Array when draining the queue.
        runInViewModelUpdateTransaction {
            var nextEvent = 0
            while nextEvent < pendingStateEvents.count, !isDisposed {
                let event = pendingStateEvents[nextEvent]
                nextEvent += 1
                let snapshot = stateListeners
                for entry in snapshot {
                    if isDisposed { break }
                    guard stateListeners.contains(where: { $0.id == entry.id }) else { continue }
                    do {
                        try entry.callback(event.previous, event.current)
                    } catch {
                        reportViewModelError(
                            error, type: .listener, context: "stateListener error")
                    }
                }
                if !isDisposed { notifyListeners() }
            }
        }
    }

    open override func dispose() {
        pendingStateEvents.removeAll()
        stateListeners.removeAll()
        super.dispose()
    }
}
