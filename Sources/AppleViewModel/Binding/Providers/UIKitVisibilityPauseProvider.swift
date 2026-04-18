#if canImport(UIKit)
import UIKit

/// Manual pause provider wired to a specific `UIViewController`.
///
/// iOS navigation semantics differ enough from Flutter's `Navigator` that a
/// fully automatic "paused when covered" signal is hard to get right. This
/// provider is intentionally minimal — business code can call `pause()` from
/// `viewWillDisappear` and `resume()` from `viewWillAppear` to get the same
/// effect as the Dart `PageRoutePauseProvider`.
///
/// Usage:
/// ```swift
/// final class MyVC: UIViewController {
///     let visibility = UIKitVisibilityPauseProvider()
///
///     override func viewDidLoad() {
///         super.viewDidLoad()
///         viewModelBinding.addPauseProvider(visibility)
///     }
///
///     override func viewWillAppear(_ animated: Bool) {
///         super.viewWillAppear(animated); visibility.resume()
///     }
///     override func viewWillDisappear(_ animated: Bool) {
///         super.viewWillDisappear(animated); visibility.pause()
///     }
/// }
/// ```
@MainActor
public final class UIKitVisibilityPauseProvider: BasePauseProvider {
    public override init() {
        super.init()
    }
}
#endif
