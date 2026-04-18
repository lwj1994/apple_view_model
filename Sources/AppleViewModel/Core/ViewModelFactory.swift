import Foundation

/// Abstract factory that `ViewModelBinding` uses to build or look up ViewModels.
/// Equivalent to the Dart `ViewModelFactory<T>`.
///
/// Implementations must provide `build()`. `key()`, `tag()`, and `aliveForever()`
/// default to `nil` / `false`; two factories that return the same non-nil `key`
/// resolve to the same instance in the registry.
///
/// The protocol is `@MainActor` because the canonical conformer (`ViewModelSpec`)
/// holds mutable state (the test-time `proxy` slot) alongside a `@MainActor`
/// builder closure. Isolating the whole contract keeps conformance clean without
/// requiring per-field locks.
@MainActor
public protocol ViewModelFactory<VM>: AnyObject {
    associatedtype VM: ViewModel

    func build() -> VM
    func key() -> AnyHashable?
    func tag() -> AnyHashable?
    func aliveForever() -> Bool
}

public extension ViewModelFactory {
    func key() -> AnyHashable? { nil }
    func tag() -> AnyHashable? { nil }
    func aliveForever() -> Bool { false }
}
