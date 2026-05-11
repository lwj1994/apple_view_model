import Foundation

/// Dependency resolver attached to every `ViewModel`.
///
/// Equivalent to the Dart `ViewModelBindingHandler` paired with the zone-based
/// dependency resolution. `ViewModel.viewModelBinding` reads from this handler;
/// lookup order is:
///
/// 1. `dependencyBindings.first` — populated by `ViewModelBinding.createViewModel`
///    inside the builder closure immediately after `factory.build()` returns, and
///    also by `AutoDisposeInstanceController.getInstance` for cache hits. Once
///    set, this is the only path consulted; it survives across `Task.detached`,
///    old Combine sinks, UIKit target/action callbacks, etc.
/// 2. `ViewModelBinding.currentBuilding` — top of a `@MainActor`-local stack
///    pushed by `ViewModelBinding.withBuilding(_:_:)` for the duration of a
///    `factory.build()` call. Used only as a fallback during the VM's `init()`
///    body, before `addRef(...)` has been able to attach the binding.
///
/// If neither is available the caller is using `viewModelBinding` outside any
/// context, which is a programmer error.
@MainActor
public final class ViewModelBindingHandler {
    private var dependencyBindings: [ViewModelBinding] = []

    public init() {}

    @_spi(Internal)
    public func addRef(_ binding: ViewModelBinding) {
        if !dependencyBindings.contains(where: { $0 === binding }) {
            dependencyBindings.append(binding)
        }
    }

    @_spi(Internal)
    public func removeRef(_ binding: ViewModelBinding) {
        dependencyBindings.removeAll { $0 === binding }
    }

    @_spi(Internal)
    public func dispose() {
        dependencyBindings.removeAll()
    }

    @_spi(Internal)
    public var binding: ViewModelBinding {
        if let first = dependencyBindings.first {
            return first
        }
        if let current = ViewModelBinding.currentBuilding {
            return current
        }
        preconditionFailure(
            "No binding available. ViewModel must be used within a ViewModelBinding context.")
    }
}
