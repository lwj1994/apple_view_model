import XCTest
@testable import AppleViewModel

@MainActor
final class DependencyInjectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    /// A VM that uses `viewModelBinding.read(...)` inside its initializer should
    /// resolve to the binding that built it — this exercises the TaskLocal DI.
    func test_vm_to_vm_dependency_resolves_through_taskLocal() {
        let authSpec = ViewModelSpec<CounterViewModel>(
            key: "auth",
            aliveForever: true
        ) { CounterViewModel() }

        final class OrderVM: ViewModel {
            var auth: CounterViewModel!
            override init() {
                super.init()
                // During construction, `viewModelBinding` must resolve to the
                // outer binding via the TaskLocal set by `_createViewModel`.
                self.auth = viewModelBinding.read(Self.authSpec)
            }
            static var authSpec: ViewModelSpec<CounterViewModel>!
        }
        OrderVM.authSpec = authSpec

        let orderSpec = ViewModelSpec<OrderVM> { OrderVM() }
        let b = ViewModelBinding()
        let order = b.watch(orderSpec)
        XCTAssertNotNil(order.auth)

        let direct: CounterViewModel = (try? b.readCached(key: "auth")) ?? CounterViewModel()
        XCTAssertTrue(order.auth === direct)

        b.dispose()
    }

    /// Parent binding disposes → VM it created has no other owners → VM disposes too.
    func test_parent_binding_dispose_cascades_to_child_vm() {
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
        let b = ViewModelBinding()
        let vm = b.watch(spec)
        XCTAssertFalse(vm.isDisposed)
        b.dispose()
        XCTAssertTrue(vm.isDisposed)
    }

    /// Parent disposes → dependency fetched during parent construction also disposes.
    func test_parent_dispose_also_disposes_dependency_vm() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM> { DepVM() }

        final class RootVM: ViewModel {
            var dep: DepVM!
            static var spec: ViewModelSpec<DepVM>!
            override init() {
                super.init()
                dep = viewModelBinding.read(Self.spec)
            }
        }
        RootVM.spec = depSpec

        let rootSpec = ViewModelSpec<RootVM> { RootVM() }
        let b = ViewModelBinding()
        let root = b.watch(rootSpec)
        let dep = root.dep!

        b.dispose()
        XCTAssertTrue(root.isDisposed)
        XCTAssertTrue(dep.isDisposed)
    }
}
