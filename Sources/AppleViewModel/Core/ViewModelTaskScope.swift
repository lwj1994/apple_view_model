import Foundation

/// Creates and tracks unstructured Tasks owned by one ViewModel generation.
///
/// Completed Tasks are removed automatically. Active Tasks receive `cancel()`
/// when `cancelAll()` is called or when the owning ViewModel is disposed.
/// Cancellation remains cooperative, so operations must observe it before
/// applying results.
@MainActor
public final class ViewModelTaskScope {
    // All normal access stays on MainActor. The unsafe escape is limited to
    // deinit, which runs after the last reference is released and performs the
    // final cancellation fallback without requiring Swift 6.2 isolated deinit.
    nonisolated(unsafe) private var cancellationHandlers:
        [UUID: @Sendable () -> Void] = [:]
    private var isDisposed = false
    private var sequentialIOTail: Task<Void, Never>?

    var activeTaskCount: Int { cancellationHandlers.count }

    init() {}

    /// Creates a main-actor Task owned by the ViewModel generation.
    ///
    /// Use this for asynchronous I/O and result orchestration. The returned
    /// unstructured Task may continue after this method returns, but it is
    /// cancelled when the scope is cancelled or its ViewModel is disposed.
    @discardableResult
    public func task<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable () async -> Success
    ) -> Task<Success, Never> {
        track(Task(priority: priority, operation: operation))
    }

    /// Throwing counterpart of `task(priority:operation:)`.
    @discardableResult
    public func task<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> Success
    ) -> Task<Success, any Error> {
        track(Task(priority: priority, operation: operation))
    }

    /// Creates a nonisolated Task owned by the ViewModel generation.
    ///
    /// Prefer this for CPU-heavy or background async work that should leave
    /// `@MainActor` and can cooperate with Swift concurrency. Run legacy
    /// blocking APIs on a dedicated thread or queue instead. The `@Sendable`
    /// operation must not capture the ViewModel, its binding, or other
    /// main-actor-isolated mutable state.
    /// Defaults to `.userInitiated` (equivalent to `.high`); callers may override
    /// the priority. Cancellation is cooperative: the operation must check it.
    /// With `sequential: true`, the operation waits for earlier sequential IO
    /// tasks in this scope to finish, including across suspension points.
    /// Nonsequential IO and main-actor Tasks are independent of this sequence.
    /// `cancelAll()` starts a fresh sequence; cancelled work may still be running.
    @discardableResult
    public func io<Success: Sendable>(
        priority: TaskPriority? = .userInitiated,
        sequential: Bool = false,
        operation: @escaping @Sendable () async -> Success
    ) -> Task<Success, Never> {
        let predecessor = sequential ? sequentialIOTail : nil
        let task = Task.detached(priority: priority) {
            if let predecessor {
                await predecessor.value
            }
            return await operation()
        }
        if sequential {
            sequentialIOTail = Task { _ = await task.value }
        }
        return track(task)
    }

    /// Throwing counterpart of `io(priority:sequential:operation:)`.
    /// A predecessor's error does not prevent subsequent sequential work.
    @discardableResult
    public func io<Success: Sendable>(
        priority: TaskPriority? = .userInitiated,
        sequential: Bool = false,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error> {
        let predecessor = sequential ? sequentialIOTail : nil
        let task = Task.detached(priority: priority) {
            if let predecessor {
                await predecessor.value
            }
            return try await operation()
        }
        if sequential {
            sequentialIOTail = Task { _ = await task.result }
        }
        return track(task)
    }

    /// Cancels every active Task and clears the scope for reuse.
    ///
    /// This is useful when rebinding a data source while keeping the same
    /// ViewModel generation alive. New Tasks may be created afterward.
    /// New sequential IO tasks do not wait for cancelled work. Previously queued
    /// tasks keep their existing ordering and must still cooperate with cancellation.
    public func cancelAll() {
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        // Detach the old sequence before cancelling; new work gets a fresh tail.
        sequentialIOTail = nil
        for cancel in handlers {
            cancel()
        }
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        cancelAll()
    }

    private func track<Success: Sendable, Failure: Error>(
        _ task: Task<Success, Failure>
    ) -> Task<Success, Failure> {
        guard !isDisposed else {
            task.cancel()
            return task
        }

        let id = UUID()
        cancellationHandlers[id] = { task.cancel() }

        // The cleanup Task is intentionally not tracked by this scope. It owns
        // no ViewModel state and only removes the completed Task's cancel hook.
        Task { @MainActor [weak self] in
            _ = await task.result
            self?.cancellationHandlers.removeValue(forKey: id)
        }
        return task
    }

    deinit {
        let handlers = Array(cancellationHandlers.values)
        for cancel in handlers {
            cancel()
        }
    }
}
