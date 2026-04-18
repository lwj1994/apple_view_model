#if canImport(UIKit)
import UIKit

/// `UIViewController` inherits `viewModelBinding` from `NSObject`, so the UIKit
/// entry point remains `controller.viewModelBinding`.
///
/// Keeping this extension in place makes the UIKit API discoverable in generated
/// docs without duplicating the associated-object implementation.
public extension UIViewController {
}
#endif
