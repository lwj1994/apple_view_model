import Foundation

/// Global observer for ViewModel lifecycle events.
///
/// Register with `ViewModel.initialize(lifecycles: [...])` or
/// `ViewModel.addLifecycle(_:)`. Implementations receive a callback every time
/// a ViewModel is created, bound, unbound, or disposed anywhere in the process
/// — useful for analytics, debug logging, or tooling.
///
/// Corresponds to the Dart `ViewModelLifecycle` interface. All methods have
/// default no-op implementations so adopters only override what they need.
@MainActor
public protocol ViewModelLifecycle: AnyObject {
    func onCreate(_ viewModel: ViewModel, arg: InstanceArg)
    func onBind(_ viewModel: ViewModel, arg: InstanceArg, bindingId: String)
    func onUnbind(_ viewModel: ViewModel, arg: InstanceArg, bindingId: String)
    func onDispose(_ viewModel: ViewModel, arg: InstanceArg)
}

public extension ViewModelLifecycle {
    func onCreate(_ viewModel: ViewModel, arg: InstanceArg) {}
    func onBind(_ viewModel: ViewModel, arg: InstanceArg, bindingId: String) {}
    func onUnbind(_ viewModel: ViewModel, arg: InstanceArg, bindingId: String) {}
    func onDispose(_ viewModel: ViewModel, arg: InstanceArg) {}
}

/// Per-instance lifecycle contract, mirroring the 4-step contract of the Dart side.
///
/// Any object held by an `InstanceHandle` (only `ViewModel` today) must adopt this
/// protocol. The handle invokes these methods at create / bind / unbind / dispose
/// time.
@MainActor
public protocol InstanceLifeCycle: AnyObject {
    func onCreate(_ arg: InstanceArg)
    func onBind(_ arg: InstanceArg, bindingId: String)
    func onUnbind(_ arg: InstanceArg, bindingId: String)
    func onDispose(_ arg: InstanceArg)
}
