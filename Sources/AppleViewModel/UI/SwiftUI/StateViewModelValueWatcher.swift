#if canImport(SwiftUI)
import SwiftUI
import Combine

/// Strongly typed fine-grained selector for one selected value.
///
/// Equality resolution matches `listenStateSelect`: local `equals`, then the
/// global `ViewModelConfig.equals`, then `Equatable`. Use a small `Equatable`
/// struct when several fields should form one update boundary.
@MainActor
public struct StateViewModelSelector<State, Selected: Equatable, Content: View>: View {
    private let viewModel: StateViewModel<State>
    private let selector: (State) -> Selected
    private let equals: ((Selected, Selected) -> Bool)?
    private let content: (Selected) -> Content

    public init(
        viewModel: StateViewModel<State>,
        selector: @escaping (State) -> Selected,
        equals: ((Selected, Selected) -> Bool)? = nil,
        @ViewBuilder content: @escaping (Selected) -> Content
    ) {
        self.viewModel = viewModel
        self.selector = selector
        self.equals = equals
        self.content = content
    }

    public var body: some View {
        _StateViewModelSelectorInner(
            viewModel: viewModel,
            selector: selector,
            equals: equals,
            content: content
        )
        // A recycled VM is a new generation even when the surrounding SwiftUI
        // view keeps the same structural identity. Re-keying rebuilds the
        // StateObject host and therefore its selector subscription.
        .id(ObjectIdentifier(viewModel))
    }
}

@MainActor
private struct _StateViewModelSelectorInner<State, Selected: Equatable, Content: View>: View {
    let viewModel: StateViewModel<State>
    let selector: (State) -> Selected
    let equals: ((Selected, Selected) -> Bool)?
    let content: (Selected) -> Content
    @StateObject private var host: _StateViewModelSelectorHost<State, Selected>

    init(
        viewModel: StateViewModel<State>,
        selector: @escaping (State) -> Selected,
        equals: ((Selected, Selected) -> Bool)?,
        content: @escaping (Selected) -> Content
    ) {
        self.viewModel = viewModel
        self.selector = selector
        self.equals = equals
        self.content = content
        _host = StateObject(wrappedValue: _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: selector,
            equals: equals
        ))
    }

    var body: some View {
        content(host.update(
            viewModel: viewModel,
            selector: selector,
            equals: equals
        ))
    }
}

@MainActor
final class _StateViewModelSelectorHost<State, Selected: Equatable>: ObservableObject {
    private(set) var selected: Selected
    private var viewModel: StateViewModel<State>
    private var selector: (State) -> Selected
    private var selectedEquals: (Selected, Selected) -> Bool
    nonisolated(unsafe) private var disposer: (() -> Void)? = nil

    init(
        viewModel: StateViewModel<State>,
        selector: @escaping (State) -> Selected,
        equals: ((Selected, Selected) -> Bool)?
    ) {
        self.viewModel = viewModel
        self.selector = selector
        self.selectedEquals = Self.makeEquals(equals)
        selected = selector(viewModel.state)
        subscribe()
    }

    /// Mirrors Flutter's `didUpdateWidget`: every parent render refreshes the
    /// selector configuration and immediately derives the displayed value from
    /// the current state, while the raw VM subscription remains stable.
    @discardableResult
    func update(
        viewModel: StateViewModel<State>,
        selector: @escaping (State) -> Selected,
        equals: ((Selected, Selected) -> Bool)?
    ) -> Selected {
        let generationChanged = self.viewModel !== viewModel
        if generationChanged {
            disposer?()
            disposer = nil
            self.viewModel = viewModel
        }

        self.selector = selector
        selectedEquals = Self.makeEquals(equals)
        selected = selector(viewModel.state)

        if generationChanged {
            subscribe()
        }
        return selected
    }

    private func subscribe() {
        disposer = viewModel._listenStateTransition { [weak self] previous, current in
            self?.receive(previous: previous, current: current)
        }
    }

    private func receive(previous: State, current: State) {
        let previousSelected = selector(previous)
        let currentSelected = selector(current)
        guard !selectedEquals(previousSelected, currentSelected) else { return }
        objectWillChange.send()
        selected = currentSelected
    }

    private static func makeEquals(
        _ equals: ((Selected, Selected) -> Bool)?
    ) -> (Selected, Selected) -> Bool {
        if let equals { return equals }
        let globalEquals = ViewModel.config.equals
        return { previous, current in
            if let globalEquals {
                return globalEquals(previous, current)
            }
            return previous == current
        }
    }

    deinit {
        let cleanup = disposer
        Task { @MainActor in
            cleanup?()
        }
    }
}

/// Fine-grained view that rebuilds only when the outputs of one or more
/// selectors on a `StateViewModel` change.
///
/// Equivalent to the Dart `StateViewModelValueWatcher<T>`. Best paired with a
/// VM acquired via `@ReadViewModel` — if you use `@WatchViewModel` every VM
/// change still triggers a rebuild, defeating the point.
///
/// ```swift
/// @ReadViewModel(userSpec) var vm: UserViewModel
///
/// var body: some View {
///     StateViewModelValueWatcher(
///         viewModel: vm,
///         selectors: [\.name, \.age]
///     ) { state in
///         Text("\(state.name), age \(state.age)")
///     }
/// }
/// ```
@MainActor
public struct StateViewModelValueWatcher<State, Content: View>: View {
    private let viewModel: StateViewModel<State>
    private let selectors: [(State) -> AnyHashable]
    private let content: (State) -> Content

    public init(
        viewModel: StateViewModel<State>,
        selectors: [(State) -> AnyHashable],
        @ViewBuilder content: @escaping (State) -> Content
    ) {
        self.viewModel = viewModel
        self.selectors = selectors
        self.content = content
    }

    public var body: some View {
        _ValueWatcherInner(
            viewModel: viewModel,
            selectors: selectors,
            content: content
        )
        // Recycle creates a new object generation. Force the subscription host
        // to follow that identity instead of retaining listeners on the old VM.
        .id(ObjectIdentifier(viewModel))
    }
}

@MainActor
private struct _ValueWatcherInner<State, Content: View>: View {
    let viewModel: StateViewModel<State>
    let selectors: [(State) -> AnyHashable]
    let content: (State) -> Content

    @StateObject private var host: _ValueWatcherHost<State>

    init(
        viewModel: StateViewModel<State>,
        selectors: [(State) -> AnyHashable],
        content: @escaping (State) -> Content
    ) {
        self.viewModel = viewModel
        self.selectors = selectors
        self.content = content
        _host = StateObject(wrappedValue: _ValueWatcherHost(viewModel: viewModel, selectors: selectors))
    }

    var body: some View {
        content(host.update(viewModel: viewModel, selectors: selectors))
    }
}

@MainActor
final class _ValueWatcherHost<State>: ObservableObject {
    private var viewModel: StateViewModel<State>
    private var selectors: [(State) -> AnyHashable]
    private var selectedEquals: (AnyHashable, AnyHashable) -> Bool

    /// `nonisolated(unsafe)` — only accessed on MainActor (`init`) and in
    /// `deinit` (single-threaded, guaranteed sole remaining reference).
    nonisolated(unsafe) private var disposer: (() -> Void)? = nil

    init(viewModel: StateViewModel<State>, selectors: [(State) -> AnyHashable]) {
        self.viewModel = viewModel
        self.selectors = selectors
        self.selectedEquals = Self.makeEquals()
        subscribe()
    }

    /// Refresh the selector list retained by this `@StateObject`. A generation
    /// change also moves the single raw transition subscription to the new VM.
    @discardableResult
    func update(
        viewModel: StateViewModel<State>,
        selectors: [(State) -> AnyHashable]
    ) -> State {
        let generationChanged = self.viewModel !== viewModel
        if generationChanged {
            disposer?()
            disposer = nil
            self.viewModel = viewModel
        }

        self.selectors = selectors
        selectedEquals = Self.makeEquals()

        if generationChanged {
            subscribe()
        }
        return viewModel.state
    }

    private func subscribe() {
        disposer = viewModel._listenStateTransition { [weak self] previous, current in
            self?.receive(previous: previous, current: current)
        }
    }

    private func receive(previous: State, current: State) {
        let shouldRefresh = selectors.contains { selector in
            !selectedEquals(selector(previous), selector(current))
        }
        guard shouldRefresh else { return }
        objectWillChange.send()
    }

    private static func makeEquals() -> (AnyHashable, AnyHashable) -> Bool {
        let globalEquals = ViewModel.config.equals
        return { previous, current in
            if let globalEquals {
                return globalEquals(previous, current)
            }
            return previous == current
        }
    }

    deinit {
        let cleanup = disposer
        Task { @MainActor in
            cleanup?()
        }
    }
}
#endif
