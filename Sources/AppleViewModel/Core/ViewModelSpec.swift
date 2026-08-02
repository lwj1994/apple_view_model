import Foundation

/// The default, zero-argument factory declaration. Keep specs stable (normally
/// at module/file scope) and pass them to `ViewModelBinding.watch(_:)` or
/// `ViewModelBinding.read(_:)`; this is the primary resolution path.
///
/// ```swift
/// let counterSpec = ViewModelSpec<CounterViewModel> {
///     CounterViewModel()
/// }
///
/// // Intentional cross-binding sharing and retention only.
/// let authSpec = ViewModelSpec<AuthViewModel>(
///     key: "auth",
///     aliveForever: true,
///     builder: { AuthViewModel() }
/// )
/// ```
///
/// `setProxy(_:)` remains the legacy global test override. Prefer
/// `overrideWith(_:)` for an explicitly restorable synchronous scope and
/// `runWithOverride(_:operation:)` for async/task-local isolation.
/// Every `aliveForever` spec must also configure an explicit non-nil key.
///
/// Mirrors the Dart `ViewModelSpec<T>`.
@MainActor
public final class ViewModelSpec<T: ViewModel>: ViewModelFactory {
    public typealias VM = T

    public let builder: @MainActor () -> T
    private let throwingBuilder: @MainActor () throws -> T
    private let _key: AnyHashable?
    private let _tag: AnyHashable?
    private let _aliveForever: Bool
    private let proxyState = ViewModelSpecProxyState<ViewModelSpec<T>>()

    public init(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil,
        aliveForever: Bool = false,
        builder: @escaping @MainActor () -> T
    ) {
        self.builder = builder
        self.throwingBuilder = builder
        self._key = key
        self._tag = tag
        self._aliveForever = aliveForever
    }

    /// Creates a spec whose builder can fail recoverably.
    ///
    /// Resolve this spec with `watchThrowing` / `readThrowing` when callers
    /// need to inspect the original error. The legacy `watch` / `read` APIs
    /// intentionally remain fail-fast for source compatibility.
    public init(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil,
        aliveForever: Bool = false,
        throwingBuilder: @escaping @MainActor () throws -> T
    ) {
        self.builder = {
            do {
                return try throwingBuilder()
            } catch {
                preconditionFailure("ViewModel builder failed: \(error)")
            }
        }
        self.throwingBuilder = throwingBuilder
        self._key = key
        self._tag = tag
        self._aliveForever = aliveForever
    }

    /// Install a test-time override. All factory lookups delegate to `spec` until
    /// `clearProxy()` is called.
    public func setProxy(_ spec: ViewModelSpec<T>) {
        proxyState.setProxy(spec)
    }

    public func clearProxy() {
        proxyState.clearProxy()
    }

    /// Installs a scoped override until the returned idempotent restore closure
    /// is invoked. Nested and out-of-order restores are supported.
    public func overrideWith(
        _ spec: ViewModelSpec<T>
    ) -> @MainActor () -> Void {
        proxyState.overrideWith(spec)
    }

    /// Runs `operation` with a task-local override and always restores the
    /// previous selection after success or failure. Overlapping async bodies
    /// remain isolated from one another.
    public func runWithOverride<Result>(
        _ spec: ViewModelSpec<T>,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        try await proxyState.runWithOverride(spec, operation: operation)
    }

    public func build() -> T {
        do {
            return try buildThrowing()
        } catch {
            preconditionFailure("ViewModel builder failed: \(error)")
        }
    }

    public func buildThrowing() throws -> T {
        if let proxy = proxyState.activeProxy {
            return try proxy.buildThrowing()
        }
        return try throwingBuilder()
    }

    public func key() -> AnyHashable? {
        if let proxy = proxyState.activeProxy {
            return proxy.key()
        }
        return _key
    }

    public func tag() -> AnyHashable? {
        if let proxy = proxyState.activeProxy {
            return proxy.tag()
        }
        return _tag
    }

    public func aliveForever() -> Bool {
        if let proxy = proxyState.activeProxy {
            return proxy.aliveForever()
        }
        return _aliveForever
    }
}
