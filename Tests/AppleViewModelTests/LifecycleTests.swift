import XCTest
@testable import AppleViewModel

@MainActor
final class LifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_instance_lifecycle_order_on_watch_and_dispose() {
        let spec = ViewModelSpec<CounterViewModel>(key: "lc") { CounterViewModel() }
        let b = ViewModelBinding()
        let vm = b.watch(spec)

        XCTAssertEqual(vm.onCreateCalls, 1)
        XCTAssertEqual(vm.onBindCalls, 1)
        XCTAssertEqual(vm.onUnbindCalls, 0)
        XCTAssertEqual(vm.onDisposeCalls, 0)

        b.dispose()

        XCTAssertEqual(vm.onUnbindCalls, 1)
        XCTAssertEqual(vm.onDisposeCalls, 1)
    }

    func test_global_ViewModelLifecycle_hook_fires_in_order() {
        final class Recorder: ViewModelLifecycle {
            var log: [String] = []
            func onCreate(_ vm: ViewModel, arg: InstanceArg) {
                log.append("create:\(type(of: vm))")
            }
            func onBind(_ vm: ViewModel, arg: InstanceArg, bindingId: String) {
                log.append("bind")
            }
            func onUnbind(_ vm: ViewModel, arg: InstanceArg, bindingId: String) {
                log.append("unbind")
            }
            func onDispose(_ vm: ViewModel, arg: InstanceArg) {
                log.append("dispose")
            }
        }

        let recorder = Recorder()
        let remove = ViewModel.addLifecycle(recorder)
        defer { remove() }

        let spec = ViewModelSpec<CounterViewModel>(key: "lc-global") { CounterViewModel() }
        let b = ViewModelBinding()
        _ = b.watch(spec)
        b.dispose()

        XCTAssertEqual(
            recorder.log,
            ["create:CounterViewModel", "bind", "unbind", "dispose"]
        )
    }

    func test_shared_instance_counts_bind_and_unbind_per_binding() {
        let spec = ViewModelSpec<CounterViewModel>(key: "shared-lc") { CounterViewModel() }
        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()

        let vm = b1.watch(spec)
        _ = b2.watch(spec)
        // First build: one onCreate + two onBind (one per binding).
        XCTAssertEqual(vm.onCreateCalls, 1)
        XCTAssertEqual(vm.onBindCalls, 2)

        b1.dispose()
        XCTAssertEqual(vm.onUnbindCalls, 1)
        XCTAssertFalse(vm.isDisposed)

        b2.dispose()
        XCTAssertEqual(vm.onUnbindCalls, 2)
        XCTAssertEqual(vm.onDisposeCalls, 1)
    }
}
