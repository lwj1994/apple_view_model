import Foundation

/// Lightweight reactive value that pairs a piece of state with a shareable key.
///
/// Two `ObservableValue` instances that share the same `shareKey` read and write
/// the same underlying state; otherwise each value is private to its owner.
///
/// ```swift
/// // Declare anywhere (typically a top-level let).
/// let isDarkMode = ObservableValue<Bool>(initialValue: false, shareKey: "theme-dark")
///
/// // Mutate from any MainActor context.
/// isDarkMode.value = true
///
/// // Observe inside SwiftUI.
/// ObserverBuilder(observable: isDarkMode) { dark in
///     Image(systemName: dark ? "moon.fill" : "sun.max.fill")
/// }
/// ```
///
/// Mirrors the Dart `ObservableValue<T>`. Internally each key is backed by a
/// `ObservableStateViewModel<T>` registered with `InstanceManager`, so two
/// observables sharing a key really point at the same registry entry.
@MainActor
public final class ObservableValue<T> {
    public let shareKey: AnyHashable
    public let initialValue: T

    public var value: T {
        get { ensureViewModel().state }
        set { ensureViewModel().setState(newValue) }
    }

    public init(initialValue: T, shareKey: AnyHashable? = nil) {
        self.initialValue = initialValue
        self.shareKey = shareKey ?? AnyHashable(UUID())
        _ = ensureViewModel()
    }

    /// Accessor used by `ObserverBuilder` to wire up a binding for the backing VM.
    @_spi(Internal)
    public func ensureViewModel() -> ObservableStateViewModel<T> {
        if let cached, !cached.isDisposed {
            return cached
        }
        let shareKey = self.shareKey
        let initial = self.initialValue
        // The `aliveForever: true` flag keeps the state alive beyond any single
        // binding — two observers with the same key should still see each other's
        // writes even after the original binding is gone.
        let vm = try! InstanceManager.shared.get(
            ObservableStateViewModel<T>.self,
            factory: InstanceFactory(
                builder: { ObservableStateViewModel<T>(state: initial) },
                arg: InstanceArg(key: shareKey, aliveForever: true)
            )
        )
        self.cached = vm
        return vm
    }

    private var cached: ObservableStateViewModel<T>?
}

/// Backing state container shared by every `ObservableValue` that uses the same
/// `shareKey`.
///
/// This type is `public` only because `ObserverBuilder` needs a named
/// generic type to hand to `ViewModelBinding.watchCached`. Business code should
/// stick to `ObservableValue` as the front door.
@MainActor
public final class ObservableStateViewModel<T>: StateViewModel<T> {
    public override init(state: T, equals: ((T, T) -> Bool)? = nil) {
        super.init(state: state, equals: equals)
    }
}
