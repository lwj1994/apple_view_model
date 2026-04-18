#if canImport(ObjectiveC)
import Foundation
import ObjectiveC

/// Conformed-to by object hosts that want to be notified when any watched
/// ViewModel emits a change.
///
/// Typical UIKit use:
/// ```swift
/// final class TodoListView: UIView, ViewModelBindingRefreshable {
///     private lazy var vm = viewModelBinding.watch(todoSpec)
///
///     func viewModelBindingDidUpdate() {
///         setNeedsLayout()
///     }
/// }
/// ```
@MainActor
public protocol ViewModelBindingRefreshable: AnyObject {
    func viewModelBindingDidUpdate()
}

/// Private holder that ties a `HostedViewModelBinding` to an Objective-C object
/// via `objc_setAssociatedObject`, and disposes the binding from the holder's
/// `deinit` so we never leak binding state past host release.
@MainActor
final class ObjectViewModelBindingHolder: NSObject {
    let binding: HostedViewModelBinding

    init(binding: HostedViewModelBinding) {
        self.binding = binding
    }

    deinit {
        // Deinit runs on an arbitrary thread; hop back to main to dispose the binding.
        let bindingToDispose = binding
        Task { @MainActor in
            bindingToDispose.dispose()
        }
    }
}

/// Opaque storage whose address serves as a stable Obj-C associated-object key.
private nonisolated(unsafe) var objectViewModelBindingAssociationKey: UInt8 = 0

public extension NSObject {
    /// Lazy `ViewModelBinding` whose lifetime is tied to this object.
    ///
    /// - First access creates a `HostedViewModelBinding` and attaches it as an
    ///   associated object.
    /// - On host `deinit` the holder is released, and its own `deinit`
    ///   hops to `MainActor` and disposes the binding.
    /// - If the host adopts `ViewModelBindingRefreshable`, the binding's
    ///   `refresh` closure routes to `viewModelBindingDidUpdate()`.
    @MainActor
    var viewModelBinding: ViewModelBinding {
        if let holder = objc_getAssociatedObject(self, &objectViewModelBindingAssociationKey) as? ObjectViewModelBindingHolder {
            return holder.binding
        }
        let binding = HostedViewModelBinding()
        binding.refresh = { [weak self] in
            guard let refreshable = self as? ViewModelBindingRefreshable else { return }
            refreshable.viewModelBindingDidUpdate()
        }
        let holder = ObjectViewModelBindingHolder(binding: binding)
        objc_setAssociatedObject(
            self,
            &objectViewModelBindingAssociationKey,
            holder,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return binding
    }
}
#endif
