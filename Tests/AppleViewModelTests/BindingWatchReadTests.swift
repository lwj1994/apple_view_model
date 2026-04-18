import XCTest
@testable import AppleViewModel

@MainActor
final class BindingWatchReadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    // MARK: - Per-binding defaults

    func test_watch_without_key_creates_per_binding_instance() {
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()

        let vm1 = b1.watch(spec)
        let vm2 = b2.watch(spec)

        XCTAssertFalse(vm1 === vm2, "without a key every binding owns its own instance")

        b1.dispose()
        b2.dispose()
    }

    // MARK: - key-based sharing

    func test_watch_with_shared_key_yields_same_instance() {
        let spec = ViewModelSpec<CounterViewModel>(key: "shared") { CounterViewModel() }
        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()

        let vm1 = b1.watch(spec)
        let vm2 = b2.watch(spec)

        XCTAssertTrue(vm1 === vm2)

        b1.dispose()
        b2.dispose()
    }

    func test_ref_count_keeps_vm_alive_until_last_binding_disposes() {
        let spec = ViewModelSpec<CounterViewModel>(key: "shared") { CounterViewModel() }
        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()
        let vm = b1.watch(spec)
        _ = b2.watch(spec)

        b1.dispose()
        XCTAssertFalse(vm.isDisposed, "other binding still holds a reference")

        b2.dispose()
        XCTAssertTrue(vm.isDisposed, "last binding gone → auto-dispose")
    }

    // MARK: - watch vs read

    func test_read_binds_but_does_not_trigger_onUpdate() {
        final class CountingBinding: ViewModelBinding {
            var updates = 0
            override func onUpdate() { super.onUpdate(); updates += 1 }
        }
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let b = CountingBinding()

        let vm = b.read(spec)
        vm.increment()

        XCTAssertEqual(b.updates, 0, "read must not subscribe to VM notifications")
        b.dispose()
    }

    func test_watch_triggers_onUpdate_on_notify() {
        final class CountingBinding: ViewModelBinding {
            var updates = 0
            override func onUpdate() { super.onUpdate(); updates += 1 }
        }
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let b = CountingBinding()

        let vm = b.watch(spec)
        vm.increment()
        vm.increment()

        XCTAssertEqual(b.updates, 2)
        b.dispose()
    }

    // MARK: - recycle

    func test_recycle_disposes_current_instance_and_allows_recreation() {
        let spec = ViewModelSpec<CounterViewModel>(key: "recycle") { CounterViewModel() }
        let b = ViewModelBinding()
        let vm1 = b.watch(spec)
        vm1.increment()

        b.recycle(vm1)
        XCTAssertTrue(vm1.isDisposed)

        let vm2 = b.watch(spec)
        XCTAssertFalse(vm2 === vm1)
        XCTAssertEqual(vm2.count, 0)
        b.dispose()
    }

    // MARK: - aliveForever

    func test_aliveForever_keeps_instance_across_binding_disposes() {
        let spec = ViewModelSpec<CounterViewModel>(
            key: "global-auth",
            aliveForever: true
        ) { CounterViewModel() }

        let b1 = ViewModelBinding()
        let vm1 = b1.watch(spec)
        b1.dispose()
        XCTAssertFalse(vm1.isDisposed, "aliveForever must survive its binding")

        let b2 = ViewModelBinding()
        let vm2 = b2.watch(spec)
        XCTAssertTrue(vm2 === vm1, "subsequent bindings attach to the same instance")
        b2.dispose()
    }

    // MARK: - maybe cached

    func test_maybeReadCached_returns_nil_when_not_found() {
        let b = ViewModelBinding()
        let vm: CounterViewModel? = b.maybeReadCached(key: "nope")
        XCTAssertNil(vm)
        b.dispose()
    }
}
