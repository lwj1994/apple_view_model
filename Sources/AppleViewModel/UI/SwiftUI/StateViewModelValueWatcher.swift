#if canImport(SwiftUI)
import SwiftUI

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
        content(viewModel.state)
    }
}

@MainActor
final class _ValueWatcherHost<State>: ObservableObject {
    // Deliberately omitted: a cleanup `deinit` that detaches listeners.
    //
    // Swift 6's `deinit` is non-isolated by default, which makes it impossible
    // to read `@MainActor` stored properties (including the non-Sendable
    // `() -> Void` disposer closures). The compromise here is:
    //
    // * Every registered listener captures `[weak self]` — once the host is
    //   released the callbacks become no-ops.
    // * Orphaned listener closures remain attached to the backing
    //   `StateViewModel` until it itself is disposed. In practice the VM and
    //   the watcher share a host lifetime, so the leak window is negligible.
    //
    // For workloads that thrash watchers in tight loops, expose a manual
    // cleanup and call it from `.onDisappear` — left to users by design.
    init(viewModel: StateViewModel<State>, selectors: [(State) -> AnyHashable]) {
        for selector in selectors {
            _ = viewModel.listenStateSelect(
                selector: selector,
                onChanged: { [weak self] _, _ in
                    self?.objectWillChange.send()
                }
            )
        }
    }
}
#endif
