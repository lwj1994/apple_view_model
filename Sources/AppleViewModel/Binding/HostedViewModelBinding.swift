import Foundation

/// `ViewModelBinding` subclass that routes `onUpdate()` through an injectable
/// `refresh` closure.
///
/// Shared plumbing between the SwiftUI and Objective-C-host integration layers:
/// - SwiftUI `ViewModelHost` sets `refresh` to `objectWillChange.send()`,
/// - `NSObject.viewModelBinding` routes it to `viewModelBindingDidUpdate()`.
///
/// Corresponds to the Dart `WidgetViewModelBinding`.
@MainActor
open class HostedViewModelBinding: ViewModelBinding {
    /// Invoked whenever a watched ViewModel emits a change. The default value is a
    /// no-op so construction is cheap; owners patch this after `init` when they know
    /// how they want to be refreshed.
    public var refresh: () -> Void

    public init(refresh: @escaping () -> Void = {}) {
        self.refresh = refresh
        super.init()
    }

    open override func onUpdate() {
        super.onUpdate()
        refresh()
    }
}
