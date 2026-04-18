import XCTest
@testable import AppleViewModel

@MainActor
final class PauseResumeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    /// `AsyncStream` subscriptions complete on a later run loop iteration. Give
    /// the scheduler a handful of hops before asserting.
    private func yieldRunLoop() async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await Task.yield()
        }
    }

    func test_paused_updates_are_dropped_and_single_resume_update_fires() async {
        final class CountingBinding: ViewModelBinding {
            var updates = 0
            override func onUpdate() {
                super.onUpdate()
                updates += 1
            }
        }

        let provider = BasePauseProvider()
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let b = CountingBinding()
        b.addPauseProvider(provider)
        await yieldRunLoop()

        let vm = b.watch(spec)
        XCTAssertEqual(b.updates, 0)

        provider.pause()
        await yieldRunLoop()
        XCTAssertTrue(b.isPaused)

        vm.increment()
        vm.increment()
        vm.increment()
        XCTAssertEqual(b.updates, 0, "no forwarding to onUpdate while paused")

        provider.resume()
        await yieldRunLoop()
        XCTAssertFalse(b.isPaused)
        XCTAssertEqual(b.updates, 1, "resume flushes exactly one catch-up update")

        b.dispose()
        provider.dispose()
    }
}
