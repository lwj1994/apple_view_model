import XCTest
@testable import AppleViewModel

/// Keep an in-flight next() under test control. Like a continuation that has
/// already resumed, its value can finish returning after the consumer is
/// cancelled; cancellation cannot withdraw the producer's result.
@MainActor
private final class InFlightPauseProvider: ViewModelBindingPauseProvider {
    var onFirstWait: ((Int) -> Void)?
    private var nextSubscription = 0
    private var started: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Bool?, Never>] = [:]
    private var disposed = false

    var pauseStateChanges: AsyncStream<Bool> {
        let subscription = nextSubscription
        nextSubscription += 1
        return AsyncStream(unfolding: { [weak self] in
            await self?.nextValue(for: subscription)
        })
    }

    func complete(_ value: Bool, subscription: Int) {
        guard let continuation = pending.removeValue(forKey: subscription) else {
            XCTFail("The subscription must be awaiting a value before it can complete")
            return
        }
        continuation.resume(returning: value)
    }

    func dispose() {
        disposed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: nil) }
    }

    private func nextValue(for subscription: Int) async -> Bool? {
        guard !disposed else { return nil }
        return await withCheckedContinuation { continuation in
            pending[subscription] = continuation
            if started.insert(subscription).inserted {
                onFirstWait?(subscription)
            }
        }
    }
}

@MainActor
final class PauseProviderRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_removedProviderCannotRestorePauseFromAnInFlightEvent() async {
        let provider = InFlightPauseProvider()
        let waiting = expectation(description: "The provider's first next() is suspended")
        provider.onFirstWait = { _ in waiting.fulfill() }
        var pauses = 0
        var resumes = 0
        let controller = PauseAwareController(
            onPause: { pauses += 1 },
            onResume: { resumes += 1 }
        )
        defer {
            controller.dispose()
            provider.dispose()
        }
        controller.addProvider(provider)
        await fulfillment(of: [waiting], timeout: 2)

        provider.complete(true, subscription: 0)
        controller.removeProvider(provider)
        await settleEvents()

        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(pauses, 0, "Removing a provider invalidates its already-delivered event")
        XCTAssertEqual(resumes, 0)
    }

    func test_readdingSameProviderDoesNotReviveItsPreviousSubscription() async {
        let provider = InFlightPauseProvider()
        let firstWaiting = expectation(description: "The original subscription is waiting")
        let secondWaiting = expectation(description: "The replacement subscription is waiting")
        provider.onFirstWait = { subscription in
            if subscription == 0 { firstWaiting.fulfill() }
            if subscription == 1 { secondWaiting.fulfill() }
        }
        var pauses = 0
        var resumes = 0
        let controller = PauseAwareController(
            onPause: { pauses += 1 },
            onResume: { resumes += 1 }
        )
        defer {
            controller.dispose()
            provider.dispose()
        }
        controller.addProvider(provider)
        await fulfillment(of: [firstWaiting], timeout: 2)

        provider.complete(true, subscription: 0)
        controller.removeProvider(provider)
        controller.addProvider(provider)
        await fulfillment(of: [secondWaiting], timeout: 2)
        await settleEvents()

        XCTAssertFalse(controller.isPaused, "Provider identity must not authorize an older subscription")
        XCTAssertEqual(pauses, 0)
        provider.complete(true, subscription: 1)
        await settleEvents()
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(pauses, 1)
        provider.complete(false, subscription: 1)
        await settleEvents()
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(resumes, 1)
    }

    func test_removingLastPausedProviderFlushesOneMissedUpdate() async {
        let firstProvider = BasePauseProvider()
        let secondProvider = BasePauseProvider()
        let binding = HostedViewModelBinding()
        defer {
            binding.dispose()
            firstProvider.dispose()
            secondProvider.dispose()
        }
        var refreshes = 0
        binding.refresh = { refreshes += 1 }
        binding.addPauseProvider(firstProvider)
        binding.addPauseProvider(secondProvider)
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let viewModel = binding.watch(spec)
        firstProvider.pause()
        secondProvider.pause()
        await settleEvents()

        viewModel.increment()
        viewModel.increment()
        XCTAssertTrue(binding.isPaused)
        XCTAssertEqual(refreshes, 0)
        binding.removePauseProvider(firstProvider)
        XCTAssertTrue(binding.isPaused, "The other provider still requests a pause")
        XCTAssertEqual(refreshes, 0)

        binding.removePauseProvider(secondProvider)

        XCTAssertFalse(binding.isPaused)
        XCTAssertEqual(refreshes, 1)
        viewModel.increment()
        XCTAssertEqual(refreshes, 2, "Normal watch delivery resumes immediately")
    }

    func test_disposingOneBindingKeepsSharedProviderWorkingForTheOther() async {
        let provider = BasePauseProvider()
        let first = HostedViewModelBinding()
        let second = HostedViewModelBinding()
        defer {
            first.dispose()
            second.dispose()
            provider.dispose()
        }
        var firstRefreshes = 0
        var secondRefreshes = 0
        first.refresh = { firstRefreshes += 1 }
        second.refresh = { secondRefreshes += 1 }
        first.addPauseProvider(provider)
        second.addPauseProvider(provider)
        let spec = ViewModelSpec<CounterViewModel>(key: "shared-pause-provider") {
            CounterViewModel()
        }
        let viewModel = first.watch(spec)
        XCTAssertTrue(second.watch(spec) === viewModel)
        provider.pause()
        await settleEvents()
        viewModel.increment()
        XCTAssertEqual(firstRefreshes, 0)
        XCTAssertEqual(secondRefreshes, 0)

        first.dispose()
        provider.resume()
        await settleEvents()

        XCTAssertFalse(second.isPaused)
        XCTAssertFalse(viewModel.isDisposed)
        XCTAssertEqual(firstRefreshes, 0)
        XCTAssertEqual(secondRefreshes, 1)
        viewModel.increment()
        XCTAssertEqual(secondRefreshes, 2)
    }

    func test_newStreamFromDisposedProviderFinishesImmediately() async {
        let provider = BasePauseProvider()
        provider.dispose()
        let stream = provider.pauseStateChanges
        let finished = expectation(description: "A disposed provider's new stream finishes")
        var values: [Bool] = []
        let consumer = Task { @MainActor in
            for await value in stream { values.append(value) }
            finished.fulfill()
        }
        defer { consumer.cancel() }

        await fulfillment(of: [finished], timeout: 2)

        XCTAssertTrue(values.isEmpty)
    }

    private func settleEvents() async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await Task.yield()
        }
    }
}
