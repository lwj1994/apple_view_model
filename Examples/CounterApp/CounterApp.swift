import SwiftUI
import AppleViewModel

/// Reference entry point for the example app.
///
/// To run it locally:
/// 1. Create a new iOS App project in Xcode (minimum iOS 16).
/// 2. `File → Add Package Dependencies → Add Local...`, pick `apple_view_model`.
/// 3. Replace the auto-generated `App` struct with this file and copy in
///    `CounterView`, `CounterViewModel`, `ThemeToggle`, and `darkModeValue`.
/// 4. Run on a simulator or device.
@main
struct CounterApp: App {
    init() {
        // Optional but recommended: install global configuration before any
        // ViewModel is created. The static state on `ViewModel` is process-wide.
        ViewModel.initialize(
            config: ViewModelConfig(
                isLoggingEnabled: true,
                onError: { error, type in
                    print("[VM error][\(type)]: \(error)")
                }
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 24) {
                    CounterView()
                    Divider()
                    ThemeToggle()
                }
                .navigationTitle("AppleViewModel demo")
            }
        }
    }
}
