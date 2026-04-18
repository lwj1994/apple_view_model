#if canImport(SwiftUI)
import SwiftUI
import Combine

/// Property wrapper that resolves a ViewModel and rebuilds the owning view when
/// the VM notifies its listeners.
///
/// Mirrors the `watch` half of the Dart `ViewModelStateMixin`.
///
/// ```swift
/// struct CounterView: View {
///     @WatchViewModel(counterSpec) var vm: CounterViewModel
///
///     var body: some View {
///         Button("\(vm.count)") { vm.increment() }
///     }
/// }
/// ```
///
/// Each wrapper owns a dedicated `HostedViewModelBinding`. When the view
/// terminates, SwiftUI releases the `@StateObject`, the binding disposes, and
/// the wrapped VM's reference count drops by one.
@MainActor
@propertyWrapper
public struct WatchViewModel<VM: ViewModel>: DynamicProperty {
    @StateObject private var host: ViewModelHost<VM>

    public init(_ factory: any ViewModelFactory<VM>) {
        _host = StateObject(wrappedValue: ViewModelHost(factory: factory, listen: true))
    }

    public var wrappedValue: VM { host.viewModel }

    /// Escape hatch for callers that want to attach extra `listen` / `listenState`
    /// hooks to the binding, or install a custom `PauseProvider`.
    public var projectedValue: HostedViewModelBinding { host.binding }
}
#endif
