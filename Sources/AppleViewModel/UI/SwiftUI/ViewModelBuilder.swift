#if canImport(SwiftUI)
import SwiftUI

/// View wrapper that pairs a `ViewModelSpec` with a builder closure — a turnkey
/// alternative to writing `@WatchViewModel` on your `View` struct.
///
/// Equivalent to the Dart `ViewModelBuilder`.
///
/// ```swift
/// ViewModelBuilder(counterSpec) { vm in
///     Button("\(vm.count)") { vm.increment() }
/// }
/// ```
@MainActor
public struct ViewModelBuilder<VM: ViewModel, Content: View>: View {
    @WatchViewModel private var vm: VM
    private let content: (VM) -> Content

    public init(
        _ factory: any ViewModelFactory<VM>,
        @ViewBuilder content: @escaping (VM) -> Content
    ) {
        self._vm = WatchViewModel(factory)
        self.content = content
    }

    public var body: some View {
        content(vm)
    }
}

/// Cache-only builder that looks up an existing instance by share key or tag.
///
/// Equivalent to the Dart `CachedViewModelBuilder`. When no instance is found,
/// a zero-sized placeholder is rendered and the error is reported via
/// `ViewModelConfig.onError` so the miss is observable in production.
@MainActor
public struct CachedViewModelBuilder<VM: ViewModel, Content: View>: View {
    private let shareKey: AnyHashable?
    private let tag: AnyHashable?
    private let content: (VM) -> Content

    @StateObject private var host: CachedViewModelHost<VM>

    public init(
        shareKey: AnyHashable? = nil,
        tag: AnyHashable? = nil,
        @ViewBuilder content: @escaping (VM) -> Content
    ) {
        self.shareKey = shareKey
        self.tag = tag
        self.content = content
        _host = StateObject(wrappedValue: CachedViewModelHost<VM>(shareKey: shareKey, tag: tag))
    }

    public var body: some View {
        if let vm = host.viewModel {
            content(vm)
        } else {
            Color.clear.onAppear {
                reportViewModelError(
                    ViewModelError(
                        "\(VM.self) not found in CachedViewModelBuilder. key=\(String(describing: shareKey)) tag=\(String(describing: tag))"
                    ),
                    type: .listener,
                    context: "CachedViewModelBuilder not found"
                )
            }
        }
    }
}

@MainActor
final class CachedViewModelHost<VM: ViewModel>: ObservableObject {
    let binding: HostedViewModelBinding
    let viewModel: VM?

    init(shareKey: AnyHashable?, tag: AnyHashable?) {
        let b = HostedViewModelBinding()
        self.binding = b
        let vm: VM? = b.maybeWatchCached(key: shareKey, tag: tag)
        self.viewModel = vm
        b.refresh = { [weak self] in
            self?.objectWillChange.send()
        }
    }

    deinit {
        let bindingToDispose = binding
        Task { @MainActor in
            bindingToDispose.dispose()
        }
    }
}
#endif
