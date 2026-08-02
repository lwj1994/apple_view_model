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
    private let factory: any ViewModelFactory<VM>
    @StateObject private var host: ViewModelHost<VM>

    public init(_ factory: any ViewModelFactory<VM>) {
        self.factory = factory
        _host = StateObject(wrappedValue: ViewModelHost(factory: factory, listen: false))
    }

    public var wrappedValue: VM { host.update(factory: factory) }
    public var projectedValue: HostedViewModelBinding {
        _ = host.update(factory: factory)
        return host.binding
    }
}

/// Shared host shared between `@WatchViewModel` and `@ReadViewModel`.
///
/// SwiftUI handles the lifetime of the `@StateObject`, so this class is created
/// exactly once per view instance and released when the view is torn down.
@MainActor
public final class ViewModelHost<VM: ViewModel>: ObservableObject {
    nonisolated(unsafe) private var bindingStorage: HostedViewModelBinding
    private var factory: any ViewModelFactory<VM>
    private var configuredKey: AnyHashable?
    private let listen: Bool

    public var binding: HostedViewModelBinding { bindingStorage }

    /// Resolve through the binding on every access so an explicit recycle can
    /// replace the disposed generation through the normal cache-miss path.
    public var viewModel: VM {
        if listen {
            return binding.watch(factory)
        }
        return binding.read(factory)
    }

    /// Apply the newest wrapper factory without rotating a nil-key binding's
    /// private identity on ordinary parent renders. A configured key change is
    /// a real identity change, so the old owner is released and resolution
    /// continues through a fresh binding. For the same key, only the factory is
    /// replaced; a later recycle therefore builds the next generation with the
    /// latest arguments/builder.
    @discardableResult
    func update(factory: any ViewModelFactory<VM>) -> VM {
        let nextKey = factory.key()
        if configuredKey != nextKey {
            let previousBinding = bindingStorage
            let nextBinding = HostedViewModelBinding()
            bindingStorage = nextBinding
            configuredKey = nextKey
            self.factory = factory
            nextBinding.refresh = { [weak self] in
                self?.objectWillChange.send()
            }
            let nextViewModel = viewModel
            previousBinding.refresh = {}
            previousBinding.dispose()
            return nextViewModel
        } else {
            self.factory = factory
        }
        return viewModel
    }

    init(factory: any ViewModelFactory<VM>, listen: Bool) {
        let b = HostedViewModelBinding()
        self.bindingStorage = b
        self.factory = factory
        self.configuredKey = factory.key()
        self.listen = listen
        b.refresh = { [weak self] in
            self?.objectWillChange.send()
        }

        // Prime ownership immediately. In read mode regular VM notifications
        // remain ignored, while handle disposal still refreshes the host.
        _ = viewModel
    }

    deinit {
        // SwiftUI only releases the host when the view really goes away.
        // Swift 6 deinits are nonisolated; hop back to MainActor before
        // touching `binding.dispose()`.
        let bindingToDispose = bindingStorage
        Task { @MainActor in
            bindingToDispose.dispose()
        }
    }
}
#endif
