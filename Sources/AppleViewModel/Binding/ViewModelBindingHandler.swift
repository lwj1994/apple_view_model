import Foundation

/// Dependency resolver attached to every `ViewModel`.
///
/// Equivalent to the Dart `ViewModelBindingHandler` paired with the zone-based
/// dependency resolution. `ViewModel.viewModelBinding` reads from this handler;
/// lookup order is:
///
/// 1. `dependencyBindings.first` — populated by `AutoDisposeInstanceController.getInstance`
///    via `addRef(binding)` right after the VM is built, so VMs created by a binding
///    can immediately see their parent.
/// 2. `ViewModelBinding.current` (a `@TaskLocal`) — set by `ViewModelBinding._createViewModel`
///    with `$current.withValue(self) { factory.build() }` so references made from
///    inside a VM's initializer resolve to that builder's binding.
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
        if let current = ViewModelBinding._currentTaskLocal {
            return current
        }
        preconditionFailure(
            "No binding available. ViewModel must be used within a ViewModelBinding context.")
    }
}
