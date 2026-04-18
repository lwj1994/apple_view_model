import XCTest
@testable import AppleViewModel

@MainActor
final class BasicViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_notifyListeners_fires_every_registered_callback() {
        let vm = CounterViewModel()
        var a = 0
        var b = 0
        _ = vm.listen { a += 1 }
        _ = vm.listen { b += 1 }

        vm.notifyListeners()

        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 1)
    }

    func test_update_block_triggers_notifyListeners_once() {
        let vm = CounterViewModel()
        var fired = 0
        _ = vm.listen { fired += 1 }

        vm.increment()

        XCTAssertEqual(vm.count, 1)
        XCTAssertEqual(fired, 1)
    }

    func test_listen_returns_disposer_that_detaches_listener() {
        let vm = CounterViewModel()
        var fired = 0
        let disposer = vm.listen { fired += 1 }

        vm.notifyListeners()
        XCTAssertEqual(fired, 1)

        disposer()
        vm.notifyListeners()
        XCTAssertEqual(fired, 1, "listener must stop firing after dispose")
    }

    func test_addDispose_runs_in_registration_order_on_dispose() {
        let vm = CounterViewModel()
        var order: [Int] = []
        vm.addDispose { order.append(1) }
        vm.addDispose { order.append(2) }
        vm.addDispose { order.append(3) }

        vm.onDispose(InstanceArg())

        XCTAssertEqual(order, [1, 2, 3])
    }

    func test_notifyListeners_after_disposed_is_a_noop() {
        let vm = CounterViewModel()
        var fired = 0
        _ = vm.listen { fired += 1 }

        vm.onDispose(InstanceArg())
        vm.notifyListeners()

        XCTAssertEqual(fired, 0, "disposed VM should not dispatch listeners")
        XCTAssertTrue(vm.isDisposed)
    }

    func test_isDisposed_is_false_initially_and_true_after_onDispose() {
        let vm = CounterViewModel()
        XCTAssertFalse(vm.isDisposed)
        vm.onDispose(InstanceArg())
        XCTAssertTrue(vm.isDisposed)
    }

    func test_update_async_awaits_then_notifies() async throws {
        let vm = CounterViewModel()
        var fired = 0
        _ = vm.listen { fired += 1 }

        await vm.update {
            try? await Task.sleep(nanoseconds: 10_000_000)
            vm.count = vm.count + 1
        }

        XCTAssertEqual(vm.count, 1)
        XCTAssertEqual(fired, 1)
    }
}
