#if canImport(SwiftUI)
import SwiftUI
import Combine

/// "Bind but don't subscribe" counterpart of `@WatchViewModel`. Equivalent to
/// `ViewModelBinding.read`.
///
/// Use this when the view needs a reference (to call a method on user input)
/// but should not rebuild when the VM publishes changes.
///
/// ```swift
/// struct TapButton: View {
///     @ReadViewModel(counterSpec) var vm: CounterViewModel
///     var body: some View {
///         Button("Tap") { vm.increment() }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct ReadViewModel<VM: ViewModel>: DynamicProperty {
    @StateObject private var host: ViewModelHost<VM>

    public init(_ factory: any ViewModelFactory<VM>) {
        _host = StateObject(wrappedValue: ViewModelHost(factory: factory, listen: false))
    }

    public var wrappedValue: VM { host.viewModel }
    public var projectedValue: HostedViewModelBinding { host.binding }
}

/// Shared host shared between `@WatchViewModel` and `@ReadViewModel`.
///
/// SwiftUI handles the lifetime of the `@StateObject`, so this class is created
/// exactly once per view instance and released when the view is torn down.
@MainActor
public final class ViewModelHost<VM: ViewModel>: ObservableObject {
    public let binding: HostedViewModelBinding
    public let viewModel: VM

    init(factory: any ViewModelFactory<VM>, listen: Bool) {
        let b = HostedViewModelBinding()
        self.binding = b
        if listen {
            self.viewModel = b.watch(factory)
        } else {
            self.viewModel = b.read(factory)
        }
        // In "listen" mode we forward each VM change to SwiftUI by emitting
        // `objectWillChange` on the host. Read mode intentionally leaves
        // `refresh` as a no-op.
        if listen {
            b.refresh = { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        // SwiftUI only releases the host when the view really goes away.
        // Swift 6 deinits are nonisolated; hop back to MainActor before
        // touching `binding.dispose()`.
        let bindingToDispose = binding
        Task { @MainActor in
            bindingToDispose.dispose()
        }
    }
}
#endif
