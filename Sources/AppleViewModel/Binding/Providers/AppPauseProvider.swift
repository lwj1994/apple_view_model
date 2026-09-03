#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

#if os(watchOS) || canImport(UIKit)

/// Pause provider driven by app foreground / background transitions.
///
/// On UIKit platforms, subscribes to the scene notifications:
/// - `UIScene.willDeactivateNotification` → pause,
/// - `UIScene.didActivateNotification` → resume.
///
/// On watchOS, subscribes to the WatchKit extension notifications:
/// - `WKExtension.applicationWillResignActiveNotification` → pause,
/// - `WKExtension.applicationDidBecomeActiveNotification` → resume.
///
/// Mirrors the Dart `AppPauseProvider`, which listens to
/// `AppLifecycleState.hidden` / `.resumed` instead.
@MainActor
public final class AppPauseProvider: BasePauseProvider {
    private var observers: [NSObjectProtocol] = []

    public override init() {
        super.init()
        let center = NotificationCenter.default

#if os(watchOS)
        let willDeactivateNotification = WKExtension.applicationWillResignActiveNotification
        let didActivateNotification = WKExtension.applicationDidBecomeActiveNotification
#else
        let willDeactivateNotification = UIScene.willDeactivateNotification
        let didActivateNotification = UIScene.didActivateNotification
#endif

        let deactivated = center.addObserver(
            forName: willDeactivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
        let activated = center.addObserver(
            forName: didActivateNotification,
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
