import XCTest
@testable import AppleViewModel

@MainActor
final class ArgSpecTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_arg1_same_arg_shares_instance() {
        let spec = ViewModelSpecWithArg<CounterViewModel, String>(
            builder: { _ in CounterViewModel() },
            key: { userId in "user-\(userId)" }
        )
        let b = ViewModelBinding()
        let vm1 = b.watch(spec("abc"))
        let vm2 = b.watch(spec("abc"))
        XCTAssertTrue(vm1 === vm2)
        b.dispose()
    }

    func test_arg1_different_args_create_distinct_instances() {
        let spec = ViewModelSpecWithArg<CounterViewModel, String>(
            builder: { _ in CounterViewModel() },
            key: { userId in "user-\(userId)" }
        )
        let b = ViewModelBinding()
        let a = b.watch(spec("abc"))
        let d = b.watch(spec("def"))
        XCTAssertFalse(a === d)
        b.dispose()
    }

    func test_arg2_generates_composite_key() {
        let spec = ViewModelSpecWithArg2<CounterViewModel, String, Int>(
            builder: { _, _ in CounterViewModel() },
            key: { room, limit in "chat-\(room)-\(limit)" }
        )
        let b = ViewModelBinding()
        let v1 = b.watch(spec("roomA", 10))
        let v2 = b.watch(spec("roomA", 10))
        let v3 = b.watch(spec("roomA", 20))
        XCTAssertTrue(v1 === v2)
        XCTAssertFalse(v1 === v3)
        b.dispose()
    }

    func test_arg_spec_setProxy_overrides_builder() {
        final class Mock: CounterViewModel {}
        let spec = ViewModelSpecWithArg<CounterViewModel, String>(
            builder: { _ in CounterViewModel() },
            key: { "user-\($0)" }
        )
        spec.setProxy(ViewModelSpecWithArg<CounterViewModel, String>(
            builder: { _ in Mock() },
            key: { "user-\($0)" }
        ))

        let b = ViewModelBinding()
        let vm = b.watch(spec("x"))
        XCTAssertTrue(vm is Mock)
        b.dispose()
    }

    func test_arg_aliveForever_respected() {
        let spec = ViewModelSpecWithArg<CounterViewModel, String>(
            builder: { _ in CounterViewModel() },
            key: { "user-\($0)" },
            aliveForever: { _ in true }
        )
        let b1 = ViewModelBinding()
        let vm = b1.watch(spec("a"))
        b1.dispose()
        XCTAssertFalse(vm.isDisposed)
    }
}
