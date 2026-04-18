import Foundation
import os

/// Global configuration for the ViewModel system.
///
/// Install once via `ViewModel.initialize(config:lifecycles:)`. Typical uses:
/// - enable debug logging during development,
/// - install a cross-cutting state-equality policy, or
/// - route framework errors into an analytics / crash-reporting pipeline.
///
/// Corresponds to the Dart package's `ViewModelConfig`.
public struct ViewModelConfig: Sendable {
    /// Whether `viewModelLog` output is emitted. Off by default for release builds.
    public let isLoggingEnabled: Bool

    /// Global state-equality policy.
    ///
    /// If provided, `StateViewModel.setState` and `listenStateSelect` use this
    /// closure instead of the default `===` (for reference types) / "always differ"
    /// (for value types).
    ///
    /// Resolution order: instance-level `equals` → this global policy → default.
    public let equals: (@Sendable (Any?, Any?) -> Bool)?

    /// Global error sink.
    ///
    /// Called for any exception raised inside listener, lifecycle, dispose, or
    /// pause/resume callbacks. When unset, the framework falls back to `os.Logger`.
    public let onError: (@Sendable (Error, ErrorType) -> Void)?

    public init(
        isLoggingEnabled: Bool = false,
        equals: (@Sendable (Any?, Any?) -> Bool)? = nil,
        onError: (@Sendable (Error, ErrorType) -> Void)? = nil
    ) {
        self.isLoggingEnabled = isLoggingEnabled
        self.equals = equals
        self.onError = onError
    }
}

/// Thread-safe, actor-agnostic storage for the framework's global configuration.
///
/// Reads dominate writes (writes happen once at `ViewModel.initialize` and
/// possibly in tests), so an `OSAllocatedUnfairLock` is both cheap and correct.
/// The lock lets `viewModelLog` and `reportViewModelError` run from any
/// isolation domain — background tasks, `AsyncStream` termination handlers,
/// `@Sendable onError` callbacks — without hopping to the main actor.
@_spi(Internal)
public enum ViewModelGlobalConfig {
    private static let storage = OSAllocatedUnfairLock<ViewModelConfig>(
        initialState: ViewModelConfig()
    )

    /// Snapshot read. Cheap; safe to call from any actor.
    public static var current: ViewModelConfig {
        storage.withLock { $0 }
    }

    /// Overwrite the global configuration. Safe to call from any actor; in
    /// practice it is invoked from `ViewModel.initialize` on the main actor.
    public static func set(_ new: ViewModelConfig) {
        storage.withLock { $0 = new }
    }

    /// Reset to defaults. Test-only helper.
    public static func reset() {
        storage.withLock { $0 = ViewModelConfig() }
    }
}
