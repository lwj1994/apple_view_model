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

    func test_taskScope_cancels_mainActor_detached_and_throwing_tasks() {
        let binding = ViewModelBinding()
        let viewModel = binding.read(
            ViewModelSpec<CounterViewModel> { CounterViewModel() }
        )
        let mainActorTask = viewModel.taskScope.task {
            try? await Task.sleep(for: .seconds(60))
        }
        let detachedTask = viewModel.taskScope.detachedTask {
            try? await Task.sleep(for: .seconds(60))
            return 42
        }
        let throwingTask: Task<Void, any Error> = viewModel.taskScope.task {
            try await Task.sleep(for: .seconds(60))
        }
        let detachedThrowingTask: Task<Int, any Error> =
            viewModel.taskScope.detachedTask {
                try await Task.sleep(for: .seconds(60))
                return 42
            }

        binding.recycle(viewModel)

        XCTAssertTrue(mainActorTask.isCancelled)
        XCTAssertTrue(detachedTask.isCancelled)
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
}
