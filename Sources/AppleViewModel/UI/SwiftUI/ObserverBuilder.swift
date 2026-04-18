#if canImport(SwiftUI)
import SwiftUI

/// Single-value observer, equivalent to the Dart `ObserverBuilder<T>`.
@MainActor
public struct ObserverBuilder<T, Content: View>: View {
    private let observable: ObservableValue<T>
    private let content: (T) -> Content

    public init(
        observable: ObservableValue<T>,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.observable = observable
        self.content = content
    }

    public var body: some View {
        _InnerObserverView(
            shareKey: observable.shareKey,
            ensure: { observable.ensureViewModel() },
            content: content
        )
    }
}

/// Two-value observer.
@MainActor
public struct ObserverBuilder2<T1, T2, Content: View>: View {
    private let observable1: ObservableValue<T1>
    private let observable2: ObservableValue<T2>
    private let content: (T1, T2) -> Content

    public init(
        observable1: ObservableValue<T1>,
        observable2: ObservableValue<T2>,
        @ViewBuilder content: @escaping (T1, T2) -> Content
    ) {
        self.observable1 = observable1
        self.observable2 = observable2
        self.content = content
    }

    public var body: some View {
        _InnerObserverView(
            shareKey: observable1.shareKey,
            ensure: { observable1.ensureViewModel() },
            content: { (v1: T1) in
                _InnerObserverView(
                    shareKey: observable2.shareKey,
                    ensure: { observable2.ensureViewModel() },
                    content: { (v2: T2) in
                        content(v1, v2)
                    }
                )
            }
        )
    }
}

/// Three-value observer.
@MainActor
public struct ObserverBuilder3<T1, T2, T3, Content: View>: View {
    private let observable1: ObservableValue<T1>
    private let observable2: ObservableValue<T2>
    private let observable3: ObservableValue<T3>
    private let content: (T1, T2, T3) -> Content

    public init(
        observable1: ObservableValue<T1>,
        observable2: ObservableValue<T2>,
        observable3: ObservableValue<T3>,
        @ViewBuilder content: @escaping (T1, T2, T3) -> Content
    ) {
        self.observable1 = observable1
        self.observable2 = observable2
        self.observable3 = observable3
        self.content = content
    }

    public var body: some View {
        _InnerObserverView(
            shareKey: observable1.shareKey,
            ensure: { observable1.ensureViewModel() },
            content: { (v1: T1) in
                _InnerObserverView(
                    shareKey: observable2.shareKey,
                    ensure: { observable2.ensureViewModel() },
                    content: { (v2: T2) in
                        _InnerObserverView(
                            shareKey: observable3.shareKey,
                            ensure: { observable3.ensureViewModel() },
                            content: { (v3: T3) in
                                content(v1, v2, v3)
                            }
                        )
                    }
                )
            }
        )
    }
}

/// Internal view backing each layer of the N-value observers. Each layer owns a
/// `HostedViewModelBinding` that watches a single backing `ObservableStateViewModel`.
@MainActor
struct _InnerObserverView<T, Content: View>: View {
    private let content: (T) -> Content

    @StateObject private var host: _InnerObserverHost<T>

    init(
        shareKey: AnyHashable,
        ensure: @escaping () -> ObservableStateViewModel<T>,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.content = content
        _host = StateObject(wrappedValue: _InnerObserverHost(shareKey: shareKey, ensure: ensure))
    }

    var body: some View {
        content(host.currentValue)
    }
}

@MainActor
final class _InnerObserverHost<T>: ObservableObject {
    let binding: HostedViewModelBinding
    private let vm: ObservableStateViewModel<T>

    var currentValue: T { vm.state }

    init(shareKey: AnyHashable, ensure: () -> ObservableStateViewModel<T>) {
        // Ensure the backing VM exists before we try to watch it by key.
        _ = ensure()
        let b = HostedViewModelBinding()
        self.binding = b
        self.vm = (try? b.watchCached(key: shareKey, tag: nil)) ?? ensure()
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
