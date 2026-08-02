import Foundation

@MainActor
private func failFastSpecBuild<T>(_ operation: () throws -> T) -> T {
    do {
        return try operation()
    } catch {
        preconditionFailure("ViewModel builder failed: \(error)")
    }
}

/// Parametrized spec with one argument. Mirrors the Dart `ViewModelSpec.arg`.
///
/// ```swift
/// let userSpec = ViewModelSpecWithArg<UserViewModel, String>(
///     builder: { userId in UserViewModel(userId: userId) },
///     key: { "user-\($0)" }
/// )
///
/// // `userSpec("abc")` returns a fully resolved `ViewModelSpec<UserViewModel>`.
/// binding.watch(userSpec("abc"))
/// ```
///
/// Arg-based specs share the same proxy mechanism as plain `ViewModelSpec`.
@MainActor
public final class ViewModelSpecWithArg<T: ViewModel, A> {
    public let builder: @MainActor (A) -> T
    private let throwingBuilder: @MainActor (A) throws -> T
    public let keyFn: (@MainActor (A) -> AnyHashable?)?
    public let tagFn: (@MainActor (A) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A) -> Bool)?

    private let proxyState = ViewModelSpecProxyState<ViewModelSpecWithArg<T, A>>()

    public init(
        builder: @escaping @MainActor (A) -> T,
        key: (@MainActor (A) -> AnyHashable?)? = nil,
        tag: (@MainActor (A) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A) -> Bool)? = nil
    ) {
        self.builder = builder
        self.throwingBuilder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public init(
        throwingBuilder: @escaping @MainActor (A) throws -> T,
        key: (@MainActor (A) -> AnyHashable?)? = nil,
        tag: (@MainActor (A) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A) -> Bool)? = nil
    ) {
        self.builder = { arg in
            failFastSpecBuild { try throwingBuilder(arg) }
        }
        self.throwingBuilder = throwingBuilder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg<T, A>) {
        proxyState.setProxy(spec)
    }

    public func clearProxy() {
        proxyState.clearProxy()
    }

    public func overrideWith(
        _ spec: ViewModelSpecWithArg<T, A>
    ) -> @MainActor () -> Void {
        proxyState.overrideWith(spec)
    }

    public func runWithOverride<Result>(
        _ spec: ViewModelSpecWithArg<T, A>,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        try await proxyState.runWithOverride(spec, operation: operation)
    }

    /// Apply the argument and produce a ready-to-use `ViewModelSpec<T>`.
    public func callAsFunction(_ a: A) -> ViewModelSpec<T> {
        let active = proxyState.activeProxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a),
            tag: active.tagFn?(a),
            aliveForever: active.aliveForeverFn?(a) ?? false,
            throwingBuilder: { try active.throwingBuilder(a) }
        )
    }
}

/// Two-argument variant.
@MainActor
public final class ViewModelSpecWithArg2<T: ViewModel, A, B> {
    public let builder: @MainActor (A, B) -> T
    private let throwingBuilder: @MainActor (A, B) throws -> T
    public let keyFn: (@MainActor (A, B) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B) -> Bool)?

    private let proxyState = ViewModelSpecProxyState<ViewModelSpecWithArg2<T, A, B>>()

    public init(
        builder: @escaping @MainActor (A, B) -> T,
        key: (@MainActor (A, B) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B) -> Bool)? = nil
    ) {
        self.builder = builder
        self.throwingBuilder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public init(
        throwingBuilder: @escaping @MainActor (A, B) throws -> T,
        key: (@MainActor (A, B) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B) -> Bool)? = nil
    ) {
        self.builder = { first, second in
            failFastSpecBuild { try throwingBuilder(first, second) }
        }
        self.throwingBuilder = throwingBuilder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg2<T, A, B>) {
        proxyState.setProxy(spec)
    }
    public func clearProxy() { proxyState.clearProxy() }
    public func overrideWith(
        _ spec: ViewModelSpecWithArg2<T, A, B>
    ) -> @MainActor () -> Void {
        proxyState.overrideWith(spec)
    }
    public func runWithOverride<Result>(
        _ spec: ViewModelSpecWithArg2<T, A, B>,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        try await proxyState.runWithOverride(spec, operation: operation)
    }

    public func callAsFunction(_ a: A, _ b: B) -> ViewModelSpec<T> {
        let active = proxyState.activeProxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b),
            tag: active.tagFn?(a, b),
            aliveForever: active.aliveForeverFn?(a, b) ?? false,
            throwingBuilder: { try active.throwingBuilder(a, b) }
        )
    }
}

/// Three-argument variant.
@MainActor
public final class ViewModelSpecWithArg3<T: ViewModel, A, B, C> {
    public let builder: @MainActor (A, B, C) -> T
    private let throwingBuilder: @MainActor (A, B, C) throws -> T
    public let keyFn: (@MainActor (A, B, C) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B, C) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B, C) -> Bool)?

    private let proxyState = ViewModelSpecProxyState<ViewModelSpecWithArg3<T, A, B, C>>()

    public init(
        builder: @escaping @MainActor (A, B, C) -> T,
        key: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C) -> Bool)? = nil
    ) {
        self.builder = builder
        self.throwingBuilder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public init(
        throwingBuilder: @escaping @MainActor (A, B, C) throws -> T,
        key: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C) -> Bool)? = nil
    ) {
        self.builder = { first, second, third in
            failFastSpecBuild { try throwingBuilder(first, second, third) }
        }
        self.throwingBuilder = throwingBuilder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg3<T, A, B, C>) {
        proxyState.setProxy(spec)
    }
    public func clearProxy() { proxyState.clearProxy() }
    public func overrideWith(
        _ spec: ViewModelSpecWithArg3<T, A, B, C>
    ) -> @MainActor () -> Void {
        proxyState.overrideWith(spec)
    }
    public func runWithOverride<Result>(
        _ spec: ViewModelSpecWithArg3<T, A, B, C>,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        try await proxyState.runWithOverride(spec, operation: operation)
    }

    public func callAsFunction(_ a: A, _ b: B, _ c: C) -> ViewModelSpec<T> {
        let active = proxyState.activeProxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b, c),
            tag: active.tagFn?(a, b, c),
            aliveForever: active.aliveForeverFn?(a, b, c) ?? false,
            throwingBuilder: { try active.throwingBuilder(a, b, c) }
        )
    }
}

/// Four-argument variant.
@MainActor
public final class ViewModelSpecWithArg4<T: ViewModel, A, B, C, D> {
    public let builder: @MainActor (A, B, C, D) -> T
    private let throwingBuilder: @MainActor (A, B, C, D) throws -> T
    public let keyFn: (@MainActor (A, B, C, D) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B, C, D) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B, C, D) -> Bool)?

    private let proxyState = ViewModelSpecProxyState<ViewModelSpecWithArg4<T, A, B, C, D>>()

    public init(
        builder: @escaping @MainActor (A, B, C, D) -> T,
        key: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C, D) -> Bool)? = nil
    ) {
        self.builder = builder
        self.throwingBuilder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public init(
        throwingBuilder: @escaping @MainActor (A, B, C, D) throws -> T,
        key: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C, D) -> Bool)? = nil
    ) {
        self.builder = { first, second, third, fourth in
            failFastSpecBuild { try throwingBuilder(first, second, third, fourth) }
        }
        self.throwingBuilder = throwingBuilder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg4<T, A, B, C, D>) {
        proxyState.setProxy(spec)
    }
    public func clearProxy() { proxyState.clearProxy() }
    public func overrideWith(
        _ spec: ViewModelSpecWithArg4<T, A, B, C, D>
    ) -> @MainActor () -> Void {
        proxyState.overrideWith(spec)
    }
    public func runWithOverride<Result>(
        _ spec: ViewModelSpecWithArg4<T, A, B, C, D>,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        try await proxyState.runWithOverride(spec, operation: operation)
    }

    public func callAsFunction(_ a: A, _ b: B, _ c: C, _ d: D) -> ViewModelSpec<T> {
        let active = proxyState.activeProxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b, c, d),
            tag: active.tagFn?(a, b, c, d),
            aliveForever: active.aliveForeverFn?(a, b, c, d) ?? false,
            throwingBuilder: { try active.throwingBuilder(a, b, c, d) }
        )
    }
}
