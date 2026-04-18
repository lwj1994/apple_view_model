import Foundation

/// The default, zero-argument factory declaration.
///
/// ```swift
/// let counterSpec = ViewModelSpec<CounterViewModel> {
///     CounterViewModel()
/// }
///
/// let authSpec = ViewModelSpec<AuthViewModel>(
///     key: "auth",
///     aliveForever: true,
///     builder: { AuthViewModel() }
/// )
/// ```
///
/// `setProxy(_:)` replaces the live builder / key / tag / aliveForever values
/// for testing. Call `clearProxy()` to revert.
///
/// Mirrors the Dart `ViewModelSpec<T>`.
@MainActor
public final class ViewModelSpec<T: ViewModel>: ViewModelFactory {
    public typealias VM = T

    public let builder: @MainActor () -> T
    private let _key: AnyHashable?
    private let _tag: AnyHashable?
    private let _aliveForever: Bool
    private var proxy: ViewModelSpec<T>?

    public init(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil,
        aliveForever: Bool = false,
        builder: @escaping @MainActor () -> T
    ) {
        self.builder = builder
        self._key = key
        self._tag = tag
        self._aliveForever = aliveForever
    }

    /// Install a test-time override. All factory lookups delegate to `spec` until
    /// `clearProxy()` is called.
    public func setProxy(_ spec: ViewModelSpec<T>) {
        proxy = spec
    }

    public func clearProxy() {
        proxy = nil
    }

    public func build() -> T {
        (proxy?.builder ?? builder)()
    }

    public func key() -> AnyHashable? {
        proxy?._key ?? _key
    }

    public func tag() -> AnyHashable? {
        proxy?._tag ?? _tag
    }

    public func aliveForever() -> Bool {
        proxy?._aliveForever ?? _aliveForever
    }
}
