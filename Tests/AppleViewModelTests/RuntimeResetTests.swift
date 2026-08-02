import XCTest
@testable import AppleViewModel

@MainActor
private final class ResetTrackedViewModel: ViewModel {}

@MainActor
private final class ResetReentrantViewModel: ViewModel {
    private let attemptResolution: () -> Void

    init(attemptResolution: @escaping () -> Void) {
        self.attemptResolution = attemptResolution
        super.init()
    }

    override func dispose() {
        attemptResolution()
        super.dispose()
    }
}

@MainActor
private final class ResetLifecycleRecorder: ViewModelLifecycle {
    private(set) var disposed: [ObjectIdentifier] = []

    func onDispose(_ viewModel: ViewModel, arg: InstanceArg) {
        disposed.append(ObjectIdentifier(viewModel))
    }
}

@MainActor
private final class ResetResolutionRecorder {
    var error: Error?
}

@MainActor
final class RuntimeResetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_resetDisposesRetainedInstancesClearsRuntimeAndAllowsReinitialize() {
        let lifecycle = ResetLifecycleRecorder()
        ViewModel.initialize(
            config: ViewModelConfig(isLoggingEnabled: true),
            lifecycles: [lifecycle]
        )
        let spec = ViewModelSpec<ResetTrackedViewModel>(
            key: "reset-retained",
            aliveForever: true
        ) {
            ResetTrackedViewModel()
        }
        let binding = ViewModelBinding()
        let retained = binding.read(spec)

        binding.dispose()
        XCTAssertFalse(retained.isDisposed)
        XCTAssertGreaterThan(InstanceManager.shared.debugStoreCount, 0)

        ViewModel.reset()

        XCTAssertTrue(retained.isDisposed)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        XCTAssertEqual(lifecycle.disposed, [ObjectIdentifier(retained)])
        XCTAssertFalse(ViewModel.config.isLoggingEnabled)

        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        XCTAssertTrue(ViewModel.config.isLoggingEnabled)
    }

    func test_resetRejectsReentrantResolutionDuringDispose() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let recorder = ResetResolutionRecorder()
        var targetBuilds = 0
        let targetSpec = ViewModelSpec<ResetTrackedViewModel>(key: "created-during-reset") {
            targetBuilds += 1
            return ResetTrackedViewModel()
        }
        let retainedSpec = ViewModelSpec<ResetReentrantViewModel>(
            key: "reset-reentrant",
            aliveForever: true
        ) {
            ResetReentrantViewModel {
                do {
                    _ = try binding.readThrowing(targetSpec)
                } catch {
                    recorder.error = error
                }
            }
        }
        let retained = binding.read(retainedSpec)

        ViewModel.reset()

        XCTAssertTrue(retained.isDisposed)
        XCTAssertTrue(recorder.error is ViewModelError)
        XCTAssertEqual(targetBuilds, 0)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }

    func test_resetInsideBuilderDisposesDetachedGenerationAndDoesNotCacheIt() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var created: ResetTrackedViewModel?
        let spec = ViewModelSpec<ResetTrackedViewModel>(key: "reset-inside-builder") {
            ViewModel.reset()
            let value = ResetTrackedViewModel()
            created = value
            return value
        }

        XCTAssertThrowsError(try binding.readThrowing(spec)) { error in
            XCTAssertTrue(error is ViewModelError)
            XCTAssertTrue(String(describing: error).contains("disposed"))
            XCTAssertTrue(String(describing: error).contains("not cached"))
        }

        XCTAssertNotNil(created)
        XCTAssertTrue(created?.isDisposed == true)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        let cached: ResetTrackedViewModel? = try? ViewModel.readCached(
            key: "reset-inside-builder"
        )
        XCTAssertNil(cached)
    }
}
