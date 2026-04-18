import Foundation
import os

/// Shared logger for the AppleViewModel framework.
///
/// Unified entry point so users can filter by subsystem via Console.app or
/// `log stream --subsystem tech.echoing.AppleViewModel`.
@usableFromInline
let appleViewModelLogger = Logger(
    subsystem: "tech.echoing.AppleViewModel",
    category: "ViewModel"
)

/// Emits a debug-level log line when `ViewModelConfig.isLoggingEnabled` is true.
///
/// The closure is lazily evaluated, so string interpolation is free when
/// logging is disabled in release builds.
///
/// Safe to call from any actor — configuration lookup goes through a lock-
/// protected snapshot, so background tasks and `@Sendable` closures can log
/// framework activity without hopping to the main actor.
@inlinable
public func viewModelLog(
    _ message: @autoclosure () -> String,
    function: StaticString = #function,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard ViewModel.config.isLoggingEnabled else { return }
    let fileName = ("\(file)" as NSString).lastPathComponent
    let resolved = message()
    let fn = String(describing: function)
    appleViewModelLogger.debug(
        "\(fileName, privacy: .public):\(line, privacy: .public) \(fn, privacy: .public) — \(resolved, privacy: .public)"
    )
}

/// Routes an error to the user-provided `onError` handler, or logs it if
/// no handler was installed.
///
/// This never rethrows: one failing listener or lifecycle hook must not
/// cascade into the rest of the framework. Safe to call from any actor
/// (the `onError` closure is `@Sendable`).
public func reportViewModelError(
    _ error: Error,
    type: ErrorType,
    context: String
) {
    if let handler = ViewModel.config.onError {
        handler(error, type)
        return
    }
    appleViewModelLogger.error("[\(String(describing: type), privacy: .public)] \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
}
