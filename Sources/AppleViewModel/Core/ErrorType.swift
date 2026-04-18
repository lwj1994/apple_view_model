import Foundation

/// Error thrown by the ViewModel system for expected failure modes such as
/// "cache miss", "used after dispose", or "invalid argument".
///
/// Corresponds to the Dart package's `ViewModelError`.
public struct ViewModelError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        "ViewModel error: \(message)"
    }
}

/// Error category passed as the third argument to `ViewModelConfig.onError`.
///
/// Matches the Dart `ErrorType` enum one-to-one.
public enum ErrorType: Sendable {
    /// Thrown from listener callbacks (`notifyListeners`, `listen`, `listenState`, ...).
    case listener
    /// Thrown from lifecycle callbacks (`onCreate`, `onBind`, `onUnbind`).
    case lifecycle
    /// Thrown from cleanup (`dispose`, `onDispose`, `addDispose` blocks).
    case dispose
    /// Thrown from PauseProvider subscription or pause/resume callbacks.
    case pauseResume
}
