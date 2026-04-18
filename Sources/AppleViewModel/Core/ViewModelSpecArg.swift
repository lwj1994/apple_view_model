import Foundation

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
    public let keyFn: (@MainActor (A) -> AnyHashable?)?
    public let tagFn: (@MainActor (A) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A) -> Bool)?

    private var proxy: ViewModelSpecWithArg<T, A>?

    public init(
        builder: @escaping @MainActor (A) -> T,
        key: (@MainActor (A) -> AnyHashable?)? = nil,
        tag: (@MainActor (A) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A) -> Bool)? = nil
    ) {
        self.builder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg<T, A>) {
        proxy = spec
    }

    public func clearProxy() {
        proxy = nil
    }

    /// Apply the argument and produce a ready-to-use `ViewModelSpec<T>`.
    public func callAsFunction(_ a: A) -> ViewModelSpec<T> {
        let active = proxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a),
            tag: active.tagFn?(a),
            aliveForever: active.aliveForeverFn?(a) ?? false,
            builder: { active.builder(a) }
        )
    }
}

/// Two-argument variant.
@MainActor
public final class ViewModelSpecWithArg2<T: ViewModel, A, B> {
    public let builder: @MainActor (A, B) -> T
    public let keyFn: (@MainActor (A, B) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B) -> Bool)?

    private var proxy: ViewModelSpecWithArg2<T, A, B>?

    public init(
        builder: @escaping @MainActor (A, B) -> T,
        key: (@MainActor (A, B) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B) -> Bool)? = nil
    ) {
        self.builder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg2<T, A, B>) { proxy = spec }
    public func clearProxy() { proxy = nil }

    public func callAsFunction(_ a: A, _ b: B) -> ViewModelSpec<T> {
        let active = proxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b),
            tag: active.tagFn?(a, b),
            aliveForever: active.aliveForeverFn?(a, b) ?? false,
            builder: { active.builder(a, b) }
        )
    }
}

/// Three-argument variant.
@MainActor
public final class ViewModelSpecWithArg3<T: ViewModel, A, B, C> {
    public let builder: @MainActor (A, B, C) -> T
    public let keyFn: (@MainActor (A, B, C) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B, C) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B, C) -> Bool)?

    private var proxy: ViewModelSpecWithArg3<T, A, B, C>?

    public init(
        builder: @escaping @MainActor (A, B, C) -> T,
        key: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C) -> Bool)? = nil
    ) {
        self.builder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg3<T, A, B, C>) { proxy = spec }
    public func clearProxy() { proxy = nil }

    public func callAsFunction(_ a: A, _ b: B, _ c: C) -> ViewModelSpec<T> {
        let active = proxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b, c),
            tag: active.tagFn?(a, b, c),
            aliveForever: active.aliveForeverFn?(a, b, c) ?? false,
            builder: { active.builder(a, b, c) }
        )
    }
}

/// Four-argument variant.
@MainActor
public final class ViewModelSpecWithArg4<T: ViewModel, A, B, C, D> {
    public let builder: @MainActor (A, B, C, D) -> T
    public let keyFn: (@MainActor (A, B, C, D) -> AnyHashable?)?
    public let tagFn: (@MainActor (A, B, C, D) -> AnyHashable?)?
    public let aliveForeverFn: (@MainActor (A, B, C, D) -> Bool)?

    private var proxy: ViewModelSpecWithArg4<T, A, B, C, D>?

    public init(
        builder: @escaping @MainActor (A, B, C, D) -> T,
        key: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        tag: (@MainActor (A, B, C, D) -> AnyHashable?)? = nil,
        aliveForever: (@MainActor (A, B, C, D) -> Bool)? = nil
    ) {
        self.builder = builder
        self.keyFn = key
        self.tagFn = tag
        self.aliveForeverFn = aliveForever
    }

    public func setProxy(_ spec: ViewModelSpecWithArg4<T, A, B, C, D>) { proxy = spec }
    public func clearProxy() { proxy = nil }

    public func callAsFunction(_ a: A, _ b: B, _ c: C, _ d: D) -> ViewModelSpec<T> {
        let active = proxy ?? self
        return ViewModelSpec<T>(
            key: active.keyFn?(a, b, c, d),
            tag: active.tagFn?(a, b, c, d),
            aliveForever: active.aliveForeverFn?(a, b, c, d) ?? false,
            builder: { active.builder(a, b, c, d) }
        )
    }
}
