import Foundation
import XCTest
@testable import AppleViewModel

private enum ConstructionResourceError: Error, Equatable {
    case failed
}

/// A synchronous resource whose subscriptions survive the subscriber unless
/// their explicit cancellation closure runs (like a notification observer).
@MainActor
private final class ConstructionEventSource {
    private var listeners: [UUID: () -> Void] = [:]

    func subscribe(_ listener: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in _ = self?.listeners.removeValue(forKey: id) }
    }

    func emit() {
        for listener in Array(listeners.values) { listener() }
    }
}

@MainActor
private final class FailedResourceConstructionViewModel: ViewModel {
    init(
        source: ConstructionEventSource,
        onEvent: @escaping () -> Void,
        onCleanup: @escaping () -> Void
    ) throws {
        super.init()
        addDispose(source.subscribe(onEvent))
        addDispose(onCleanup)
        throw ConstructionResourceError.failed
    }
}

@MainActor
private final class ConstructionResourceViewModel: ViewModel {
    init(onCleanup: @escaping () -> Void) {
        super.init()
        addDispose(onCleanup)
    }
}

@MainActor
private final class FailedResourceParentViewModel: ViewModel {
    init(
        childSpec: ViewModelSpec<ConstructionResourceViewModel>,
        onCleanup: @escaping () -> Void
    ) throws {
        super.init()
        addDispose(onCleanup)
        _ = try viewModelBinding.readThrowing(childSpec)
        throw ConstructionResourceError.failed
    }
}

@MainActor
final class ConstructionResourceCleanupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_failedInitializerCancelsItsSubscriptionBeforeTheErrorEscapes() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let source = ConstructionEventSource()
        var received = 0
        var cleanups = 0
        let spec = ViewModelSpec<FailedResourceConstructionViewModel>(
            throwingBuilder: {
                try FailedResourceConstructionViewModel(
                    source: source,
                    onEvent: { received += 1 },
                    onCleanup: { cleanups += 1 }
                )
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertEqual(error as? ConstructionResourceError, .failed)
        }
        XCTAssertEqual(cleanups, 1)
        source.emit()
        XCTAssertEqual(received, 0)

        binding.dispose()
        ViewModel.reset()
        XCTAssertEqual(cleanups, 1)
    }

    func test_successfulConstructionRetainsCleanupUntilNormalDisposal() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var cleanups = 0
        let spec = ViewModelSpec<ConstructionResourceViewModel> {
            ConstructionResourceViewModel(onCleanup: { cleanups += 1 })
        }
        let value = binding.read(spec)

        XCTAssertFalse(value.isDisposed)
        XCTAssertEqual(cleanups, 0)
        binding.dispose()
        binding.dispose()
        ViewModel.reset()
        XCTAssertTrue(value.isDisposed)
        XCTAssertEqual(cleanups, 1)
    }

    func test_failedParentCleansItsOwnResourcesAndCommittedChildExactlyOnce() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var parentCleanups = 0
        var childCleanups = 0
        let childSpec = ViewModelSpec<ConstructionResourceViewModel> {
            ConstructionResourceViewModel(onCleanup: { childCleanups += 1 })
        }
        let parentSpec = ViewModelSpec<FailedResourceParentViewModel>(
            throwingBuilder: {
                try FailedResourceParentViewModel(
                    childSpec: childSpec,
                    onCleanup: { parentCleanups += 1 }
                )
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(parentSpec)) { error in
            XCTAssertEqual(error as? ConstructionResourceError, .failed)
        }
        XCTAssertEqual(parentCleanups, 1)
        XCTAssertEqual(childCleanups, 1)

        binding.dispose()
        ViewModel.reset()
        XCTAssertEqual(parentCleanups, 1)
        XCTAssertEqual(childCleanups, 1)
    }

    func test_rollbackAfterUntrackedDisposalDoesNotRepeatCleanup() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var cleanups = 0
        let spec = ViewModelSpec<ConstructionResourceViewModel>(
            key: "reset-during-resource-construction",
            throwingBuilder: {
                ViewModel.reset()
                return ConstructionResourceViewModel(onCleanup: { cleanups += 1 })
            }
        )

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertTrue(error is ViewModelError)
        }
        XCTAssertEqual(cleanups, 1)

        binding.dispose()
        ViewModel.reset()
        XCTAssertEqual(cleanups, 1)
    }
}
