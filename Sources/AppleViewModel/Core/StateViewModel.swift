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
    public private(set) var previousState: State?
    public let initialState: State

    private struct StateListenerEntry {
        let id: UUID
        let callback: (State, State) throws -> Void
    }

    private let equalsFn: (State, State) -> Bool
    private var stateListeners: [StateListenerEntry] = []

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
                // Fall back to reference identity when both values are class instances.
                // For pure value types this amounts to "always different", matching the
                // Dart default behavior of `identical()`.
                if let a = prev as AnyObject?, let b = next as AnyObject? {
                    return a === b
                }
                return false
            }
        }
        super.init()
    }

    /// Subscribe to raw state changes; callback receives `(previous, current)`.
    @discardableResult
    public func listenState(
        onChanged: @escaping (State?, State) throws -> Void
    ) -> () -> Void {
        _listenStateTransition { previous, current in
            try onChanged(previous, current)
        }
    }

    /// Internal non-optional state transition stream used by selector hosts.
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
    @discardableResult
    public func listenStateSelect<R: Equatable>(
        selector: @escaping (State) -> R,
        equals: ((R, R) -> Bool)? = nil,
        onChanged: @escaping (R?, R) throws -> Void
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
        let current = newState
        previousState = previous
        state = newState
        // Phase 1: state listeners receive (previous, current).
        let snapshot = stateListeners
        for entry in snapshot {
            guard stateListeners.contains(where: { $0.id == entry.id }) else { continue }
            do {
                try entry.callback(previous, current)
            } catch {
                reportViewModelError(
                    error, type: .listener, context: "stateListener error")
            }
        }
        // Phase 2: general listeners fan out.
        notifyListeners()
    }

    open override func dispose() {
        stateListeners.removeAll()
        super.dispose()
    }
}
