import Foundation

/// Creates and tracks unstructured Tasks owned by one ViewModel generation.
///
/// Completed Tasks are removed automatically. Active Tasks receive `cancel()`
/// when `cancelAll()` is called or when the owning ViewModel is disposed.
/// Cancellation remains cooperative, so operations must observe it before
/// applying results.
@MainActor
public final class ViewModelTaskScope {
    private var cancellationHandlers: [UUID: () -> Void] = [:]
    private var isDisposed = false

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
    /// Use this only for CPU-heavy or executor-bound work that should leave
    /// `@MainActor` and can cooperate with Swift concurrency. Run legacy
    /// blocking APIs on a dedicated thread or queue instead. The `@Sendable`
    /// operation must not capture the ViewModel, its binding, or other
    /// main-actor-isolated mutable state.
    @discardableResult
    public func detachedTask<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Success
    ) -> Task<Success, Never> {
        track(Task.detached(priority: priority, operation: operation))
    }

    /// Throwing counterpart of `detachedTask(priority:operation:)`.
    @discardableResult
    public func detachedTask<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error> {
        track(Task.detached(priority: priority, operation: operation))
    }

    /// Cancels every active Task and clears the scope for reuse.
    ///
    /// This is useful when rebinding a data source while keeping the same
    /// ViewModel generation alive. New Tasks may be created afterward.
    public func cancelAll() {
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
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

    isolated deinit {
        cancelAll()
    }
}
