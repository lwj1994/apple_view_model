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

@_spi(Internal)
public enum ViewModelGlobalConfig {
    private static nonisolated(unsafe) var lock = OSAllocatedUnfairLock()
    private static nonisolated(unsafe) var _current = ViewModelConfig()

    public static var current: ViewModelConfig {
        lock.withLock { _current }
    }

    public static func set(_ new: ViewModelConfig) {
        lock.withLock { _current = new }
    }

    public static func reset() {
        lock.withLock { _current = ViewModelConfig() }
    }
}
