#if canImport(UIKit)
import UIKit

/// Pause provider driven by app foreground / background transitions.
///
/// Subscribes to the UIKit scene notifications:
/// - `UIScene.willDeactivateNotification` → pause,
/// - `UIScene.didActivateNotification` → resume.
///
/// Mirrors the Dart `AppPauseProvider`, which listens to
/// `AppLifecycleState.hidden` / `.resumed` instead.
@MainActor
public final class AppPauseProvider: BasePauseProvider {
    private var observers: [NSObjectProtocol] = []

    public override init() {
        super.init()
        let center = NotificationCenter.default
        let deactivated = center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
        let activated = center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resume()
            }
        }
        observers = [deactivated, activated]
    }

    public override func dispose() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        super.dispose()
    }
}
#endif
