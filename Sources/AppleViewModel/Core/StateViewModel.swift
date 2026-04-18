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

    private let equalsFn: (State, State) -> Bool
    private var stateListeners: [UUID: (State?, State) -> Void] = [:]

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
        onChanged: @escaping (State?, State) -> Void
    ) -> () -> Void {
        let id = UUID()
        stateListeners[id] = onChanged
        return { [weak self] in
            self?.stateListeners.removeValue(forKey: id)
        }
    }

    /// Subscribe to the output of a selector; the callback only fires when
    /// `selector(previous) != selector(current)`.
    @discardableResult
    public func listenStateSelect<R: Equatable>(
        selector: @escaping (State) -> R,
        onChanged: @escaping (R?, R) -> Void
    ) -> () -> Void {
        let wrapped: (State?, State) -> Void = { prevState, currState in
            let prevSel = prevState.map { selector($0) }
            let currSel = selector(currState)
            if prevSel != currSel {
                onChanged(prevSel, currSel)
            }
        }
        let id = UUID()
        stateListeners[id] = wrapped
        return { [weak self] in
            self?.stateListeners.removeValue(forKey: id)
        }
    }

    /// The single mutation entry point. Emits notifications when the incoming
    /// state differs from the current one according to `equalsFn`.
    public func setState(_ newState: State) {
        if isDisposed {
            viewModelLog("\(type(of: self)): setState after Disposed")
            return
        }
        if equalsFn(state, newState) { return }
        previousState = state
        state = newState
        // Phase 1: state listeners receive (previous, current).
        let snapshot = Array(stateListeners.values)
        for listener in snapshot {
            do {
                try runCatching { listener(previousState, state) }
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

    private func runCatching(_ block: () throws -> Void) throws {
        try block()
    }
}
