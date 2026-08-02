#if canImport(SwiftUI)
import SwiftUI

/// Advanced cache-only builder that looks up an existing instance by share key
/// or tag. Prefer `@WatchViewModel(spec)` for normal UI dependency resolution.
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
        if let vm = host.update(shareKey: shareKey, tag: tag) {
            content(vm)
        } else {
            Color.clear.onAppear {
                reportViewModelError(
                    ViewModelError(
                        CachedViewModelHost<VM>.missingErrorMessage(
                            shareKey: shareKey,
                            tag: tag
                        )
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
    nonisolated(unsafe) private var bindingStorage: HostedViewModelBinding
    private var shareKey: AnyHashable?
    private var tag: AnyHashable?

    var binding: HostedViewModelBinding { bindingStorage }

    static func missingErrorMessage(
        shareKey: AnyHashable?,
        tag: AnyHashable?
    ) -> String {
        "\(VM.self) not found in CachedViewModelBuilder. "
            + "shareKey=\(String(describing: shareKey)) "
            + "tag=\(String(describing: tag))"
    }

    /// Cache-only lookup remains live: after the old handle is recycled this
    /// returns `nil`, and a later render can observe a newly cached generation.
    var viewModel: VM? {
        do {
            return try binding.maybeWatchCachedThrowing(key: shareKey, tag: tag)
        } catch {
            reportViewModelError(
                error,
                type: .listener,
                context: "CachedViewModelHost lookup error"
            )
            return nil
        }
    }

    /// Keep a persistent SwiftUI `@StateObject` aligned with the latest cache
    /// query. Changing either lookup parameter releases every owner held by the
    /// previous binding before resolving against a fresh binding.
    @discardableResult
    func update(shareKey: AnyHashable?, tag: AnyHashable?) -> VM? {
        guard self.shareKey != shareKey || self.tag != tag else {
            return viewModel
        }

        let previousBinding = bindingStorage
        let nextBinding = HostedViewModelBinding()
        bindingStorage = nextBinding
        self.shareKey = shareKey
        self.tag = tag
        nextBinding.refresh = { [weak self] in
            self?.objectWillChange.send()
        }
        let nextViewModel = viewModel
        previousBinding.refresh = {}
        previousBinding.dispose()
        return nextViewModel
    }

    init(shareKey: AnyHashable?, tag: AnyHashable?) {
        let b = HostedViewModelBinding()
        self.bindingStorage = b
        self.shareKey = shareKey
        self.tag = tag
        b.refresh = { [weak self] in
            self?.objectWillChange.send()
        }
        _ = viewModel
    }

    deinit {
        let bindingToDispose = bindingStorage
        Task { @MainActor in
            bindingToDispose.dispose()
        }
    }
}
#endif
