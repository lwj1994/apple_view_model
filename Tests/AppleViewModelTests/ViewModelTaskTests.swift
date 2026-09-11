import XCTest
@testable import AppleViewModel

@MainActor
final class ViewModelTaskTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_taskScope_cancels_task_when_viewModel_is_disposed() {
        let binding = ViewModelBinding()
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let task = viewModel.taskScope.task {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertFalse(task.isCancelled)

        binding.dispose()

        XCTAssertTrue(task.isCancelled)
    }

    func test_taskScope_cancels_task_immediately_when_viewModel_is_disposed() {
        let binding = ViewModelBinding()
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        binding.dispose()

        let task = viewModel.taskScope.task {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(task.isCancelled)
    }

    func test_taskScope_cancels_task_when_scope_is_deinitialized() {
        var scope: ViewModelTaskScope? = ViewModelTaskScope()
        weak let weakScope = scope
        let task = scope!.task {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertFalse(task.isCancelled)

        scope = nil

        XCTAssertNil(weakScope)
        XCTAssertTrue(task.isCancelled)
    }

    func test_taskScope_cancels_mainActor_detached_and_throwing_tasks() {
        let binding = ViewModelBinding()
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let mainActorTask = viewModel.taskScope.task {
            try? await Task.sleep(for: .seconds(60))
        }
        let ioTask = viewModel.taskScope.io {
            try? await Task.sleep(for: .seconds(60))
            return 42
        }
        let throwingTask: Task<Void, any Error> = viewModel.taskScope.task {
            try await Task.sleep(for: .seconds(60))
        }
        let detachedThrowingTask: Task<Int, any Error> =
            viewModel.taskScope.io {
                try await Task.sleep(for: .seconds(60))
                return 42
            }

        binding.recycle(viewModel)

        XCTAssertTrue(mainActorTask.isCancelled)
        XCTAssertTrue(ioTask.isCancelled)
        XCTAssertTrue(throwingTask.isCancelled)
        XCTAssertTrue(detachedThrowingTask.isCancelled)
    }

    func test_taskScope_removes_completed_tasks() async {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let scope = viewModel.taskScope
        let task = scope.task { 42 }

        XCTAssertEqual(scope.activeTaskCount, 1)
        _ = await task.value
        for _ in 0..<10 where scope.activeTaskCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(scope.activeTaskCount, 0)
    }

    func test_cancelAll_allows_scope_reuse() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let scope = viewModel.taskScope
        let oldTask = scope.task {
            try? await Task.sleep(for: .seconds(60))
        }

        scope.cancelAll()
        let newTask = scope.task {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertFalse(newTask.isCancelled)
    }

    func test_io_defaults_to_high_priority_on_background_thread() async throws {
        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let task = scope.io {
            Self.logBackgroundThread()
            return Task.currentPriority
        }
        let throwing: Task<TaskPriority, any Error> = scope.io {
            try Task.checkCancellation()
            Self.logBackgroundThread()
            return Task.currentPriority
        }
        let priority = await task.value
        let throwingPriority = try await throwing.value
        XCTAssertEqual(priority, .userInitiated)
        XCTAssertEqual(throwingPriority, .high)
    }

    func test_io_stops_at_cancellation_point_when_viewModel_is_disposed() async {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let scope = viewModel.taskScope
        let started = expectation(description: "The IO task has started")
        let task = scope.io {
            started.fulfill()
            // Sleep suspends the worker and responds to scope cancellation.
            try await Task.sleep(for: .seconds(5))
            XCTFail("Cancelled work must not continue past the cancellation point")
            return 42
        }

        // Dispose only after the operation starts to exercise in-flight cancellation.
        await fulfillment(of: [started], timeout: 2)
        binding.dispose()

        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(scope.activeTaskCount, 0)
        do {
            _ = try await task.value
            XCTFail("The cancelled task must throw CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_io_propagates_operation_error_to_main_actor() async {
        enum WorkerError: Error, Equatable { case failed }
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let task: Task<Int, any Error> = viewModel.taskScope.io {
            Self.logBackgroundThread()
            throw WorkerError.failed
        }

        do {
            _ = try await task.value
            XCTFail("The worker error must reach the caller")
        } catch {
            // Awaiting a background task preserves the caller's actor isolation.
            MainActor.assertIsolated()
            XCTAssertEqual(error as? WorkerError, .failed)
        }
    }

    nonisolated private static func logBackgroundThread() {
        print("taskScope.io thread: \(Thread.current), isMainThread: \(Thread.isMainThread)")
        XCTAssertFalse(Thread.isMainThread, "Background work must leave the main thread")
    }
}
