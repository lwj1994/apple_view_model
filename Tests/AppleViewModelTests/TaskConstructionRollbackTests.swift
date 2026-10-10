import XCTest
@testable import AppleViewModel

private enum TaskConstructionError: Error, Equatable {
    case initializer
    case builder
}

@MainActor
private final class TaskConstructionProbe {
    var task: Task<Void, Never>?
    var finished = 0
    var observedCancellation = false
}

@MainActor
private final class TaskConstructionViewModel: ViewModel {
    private let probe: TaskConstructionProbe

    init(probe: TaskConstructionProbe, failInitializer: Bool) throws {
        self.probe = probe
        super.init()
        probe.task = taskScope.task { [self] in
            // Retaining self prevents a failed initializer from relying on the
            // scope's deinit cancellation fallback before this Task runs.
            self.probe.observedCancellation = Task.isCancelled
            self.probe.finished += 1
        }
        if failInitializer { throw TaskConstructionError.initializer }
    }
}

@MainActor
final class TaskConstructionRollbackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_failedInitializerCancelsItsSelfCapturingTaskBeforeReturning() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let probe = TaskConstructionProbe()
        let spec = ViewModelSpec<TaskConstructionViewModel>(throwingBuilder: {
            try TaskConstructionViewModel(probe: probe, failInitializer: true)
        })

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertEqual(error as? TaskConstructionError, .initializer)
        }
        let task = try XCTUnwrap(probe.task)
        defer { task.cancel() }
        XCTAssertTrue(task.isCancelled)
        await task.value
        XCTAssertTrue(probe.observedCancellation)
        XCTAssertEqual(probe.finished, 1)
    }

    func test_failedBuilderCancelsItsSelfCapturingTaskBeforeReturning() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let probe = TaskConstructionProbe()
        let spec = ViewModelSpec<TaskConstructionViewModel>(throwingBuilder: {
            _ = try TaskConstructionViewModel(probe: probe, failInitializer: false)
            throw TaskConstructionError.builder
        })

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertEqual(error as? TaskConstructionError, .builder)
        }
        let task = try XCTUnwrap(probe.task)
        defer { task.cancel() }
        XCTAssertTrue(task.isCancelled)
        await task.value
        XCTAssertTrue(probe.observedCancellation)
        XCTAssertEqual(probe.finished, 1)
    }

    func test_successfulConstructionDoesNotCancelItsCommittedTask() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let probe = TaskConstructionProbe()
        let spec = ViewModelSpec<TaskConstructionViewModel>(throwingBuilder: {
            try TaskConstructionViewModel(probe: probe, failInitializer: false)
        })

        let value = try binding.readThrowing(spec)
        let task = try XCTUnwrap(probe.task)
        defer { task.cancel() }
        XCTAssertFalse(value.isDisposed)
        XCTAssertFalse(task.isCancelled)
        await task.value
        XCTAssertFalse(probe.observedCancellation)
        XCTAssertEqual(probe.finished, 1)
        binding.dispose()
        XCTAssertTrue(value.isDisposed)
    }
}
