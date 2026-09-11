import XCTest
@testable import AppleViewModel

private actor IOTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

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

    func test_io_sequential_runs_operations_in_creation_order() async {
        actor Recorder {
            var values: [Int] = []

            func append(_ value: Int) {
                values.append(value)
            }
        }

        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let recorder = Recorder()
        let gate = IOTestGate()
        let firstStarted = expectation(description: "The first sequential operation started")
        let secondStarted = expectation(description: "The second sequential operation started")

        let first = scope.io(sequential: true) {
            firstStarted.fulfill()
            await gate.wait()
            await recorder.append(1)
            return 1
        }
        let second = scope.io(sequential: true) {
            secondStarted.fulfill()
            await recorder.append(2)
            return 2
        }

        await fulfillment(of: [firstStarted], timeout: 2)
        await gate.open()
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        await fulfillment(of: [secondStarted], timeout: 2)
        let values = await recorder.values
        XCTAssertEqual(values, [1, 2])
    }

    func test_io_sequential_continues_after_predecessor_throws() async throws {
        enum WorkerError: Error { case failed }
        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let secondStarted = expectation(description: "The successor started after the failure")

        let first: Task<Int, any Error> = scope.io(sequential: true) {
            throw WorkerError.failed
        }
        let second = scope.io(sequential: true) {
            secondStarted.fulfill()
            return 2
        }

        do {
            _ = try await first.value
            XCTFail("The predecessor must preserve its error")
        } catch is WorkerError {
            // The failure must not permanently block the sequential queue.
        }
        let value = await second.value
        XCTAssertEqual(value, 2)
        await fulfillment(of: [secondStarted], timeout: 2)
    }

    func test_io_sequential_continues_after_predecessor_cancellation() async throws {
        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let firstStarted = expectation(description: "The cancellable predecessor started")
        let secondStarted = expectation(description: "The successor started after cancellation")

        let first: Task<Int, any Error> = scope.io(sequential: true) {
            firstStarted.fulfill()
            try await Task.sleep(for: .seconds(5))
            return 1
        }
        let second = scope.io(sequential: true) {
            secondStarted.fulfill()
            return 2
        }

        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The cancelled predecessor must throw")
        } catch is CancellationError {
            // The successor should still be released by the completed predecessor.
        }
        let value = await second.value
        XCTAssertEqual(value, 2)
        await fulfillment(of: [secondStarted], timeout: 2)
    }

    func test_io_sequential_is_independent_per_scope() async {
        let firstScope = ViewModelTaskScope()
        let secondScope = ViewModelTaskScope()
        defer {
            firstScope.dispose()
            secondScope.dispose()
        }
        let gate = IOTestGate()
        let firstStarted = expectation(description: "The first scope is waiting at the gate")
        let secondStarted = expectation(description: "The other scope started independently")
        let first = firstScope.io(sequential: true) {
            firstStarted.fulfill()
            await gate.wait()
            return 1
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = secondScope.io(sequential: true) {
            secondStarted.fulfill()
            return 2
        }

        // The other scope must start while the first operation is still suspended.
        await fulfillment(of: [secondStarted], timeout: 2)
        await gate.open()
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
    }

    func test_io_without_sequential_remains_concurrent() async {
        await assertIOOperationsOverlap(firstSequential: false, secondSequential: false)
    }

    func test_io_sequential_does_not_wait_for_nonsequential_work() async {
        await assertIOOperationsOverlap(firstSequential: false, secondSequential: true)
    }

    func test_io_nonsequential_does_not_wait_for_sequential_work() async {
        await assertIOOperationsOverlap(firstSequential: true, secondSequential: false)
    }

    func test_cancelAll_starts_a_new_io_sequence_while_old_work_is_still_running() async throws {
        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let gate = IOTestGate()
        let oldStarted = expectation(description: "The old sequence is waiting at the gate")
        let freshFinished = expectation(description: "The new sequence completed independently")
        let old = scope.io(sequential: true) {
            oldStarted.fulfill()
            // Deliberately ignore cancellation until the test releases the gate.
            await gate.wait()
            return 1
        }
        let oldFollower: Task<Int, any Error> = scope.io(sequential: true) {
            try Task.checkCancellation()
            XCTFail("Cancelled work must stop at its cancellation check")
            return 2
        }
        await fulfillment(of: [oldStarted], timeout: 2)

        scope.cancelAll()
        XCTAssertEqual(scope.activeTaskCount, 0)
        XCTAssertTrue(old.isCancelled)
        XCTAssertTrue(oldFollower.isCancelled)

        let fresh = scope.io(sequential: true) { 3 }
        let freshFollower: Task<Int, any Error> = scope.io(sequential: true) {
            try Task.checkCancellation()
            freshFinished.fulfill()
            return 4
        }

        // A stale tail would block both new tasks until the old gate opens.
        await fulfillment(of: [freshFinished], timeout: 2)
        // Always release the gate after the bounded check, including on failure.
        await gate.open()
        let oldValue = await old.value
        do {
            _ = try await oldFollower.value
            XCTFail("The old follower must preserve cancellation")
        } catch is CancellationError {
            // Cancellation must not leak into the new sequence.
        }
        let freshValue = await fresh.value
        let freshFollowerValue = try await freshFollower.value
        XCTAssertEqual(oldValue, 1)
        XCTAssertEqual(freshValue, 3)
        XCTAssertEqual(freshFollowerValue, 4)
        XCTAssertFalse(fresh.isCancelled)
        XCTAssertFalse(freshFollower.isCancelled)
    }

    private func assertIOOperationsOverlap(firstSequential: Bool, secondSequential: Bool) async {
        let scope = ViewModelTaskScope()
        defer { scope.dispose() }
        let gate = IOTestGate()
        let firstStarted = expectation(description: "The first operation is waiting at the gate")
        let secondStarted = expectation(description: "The second operation started concurrently")

        let firstOperation: @Sendable () async -> Int = {
            firstStarted.fulfill()
            await gate.wait()
            return 1
        }
        let first = firstSequential
            ? scope.io(sequential: true, operation: firstOperation)
            : scope.io(operation: firstOperation)
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondOperation: @Sendable () async -> Int = {
            secondStarted.fulfill()
            return 2
        }
        let second = secondSequential
            ? scope.io(sequential: true, operation: secondOperation)
            : scope.io(operation: secondOperation)

        // A serial implementation cannot fulfill this until the gate is released.
        await fulfillment(of: [secondStarted], timeout: 2)
        await gate.open()
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
    }

    nonisolated private static func logBackgroundThread() {
        print("taskScope.io thread: \(Thread.current), isMainThread: \(Thread.isMainThread)")
        XCTAssertFalse(Thread.isMainThread, "Background work must leave the main thread")
    }
}
