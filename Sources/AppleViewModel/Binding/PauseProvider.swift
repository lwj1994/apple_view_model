import Foundation

/// Contract for anything that can signal "pause delivery" / "resume delivery"
/// to a `PauseAwareController`. Equivalent to the Dart
/// `ViewModelBindingPauseProvider`.
///
/// Providers publish events on `pauseStateChanges`:
/// - `true` → the controller should start swallowing updates,
/// - `false` → the controller should flush any missed update and resume.
///
/// The simplest way to implement one is to subclass `BasePauseProvider` and
/// call `pause()` / `resume()` from your event source.
@MainActor
public protocol ViewModelBindingPauseProvider: AnyObject {
    /// Event stream consumed by `PauseAwareController`.
    var pauseStateChanges: AsyncStream<Bool> { get }

    /// Close underlying streams and release resources.
    func dispose()
}

/// Reference implementation that exposes an imperative `pause()` / `resume()`
/// interface, internally broadcasting to every active subscriber via
/// `AsyncStream.Continuation`.
@MainActor
open class BasePauseProvider: ViewModelBindingPauseProvider {
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var disposed = false

    public init() {}

    public var pauseStateChanges: AsyncStream<Bool> {
        AsyncStream<Bool> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func pause() {
        guard !disposed else { return }
        for (_, c) in continuations { c.yield(true) }
    }

    public func resume() {
        guard !disposed else { return }
        for (_, c) in continuations { c.yield(false) }
    }

    open func dispose() {
        guard !disposed else { return }
        disposed = true
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }
}
