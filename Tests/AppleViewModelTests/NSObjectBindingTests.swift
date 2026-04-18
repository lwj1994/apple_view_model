#if canImport(ObjectiveC)
import Foundation
import XCTest
@testable import AppleViewModel

@MainActor
final class NSObjectBindingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_viewModelBinding_returns_same_binding_for_same_host() {
        let host = PlainHost()

        let binding1 = host.viewModelBinding
        let binding2 = host.viewModelBinding

        XCTAssertTrue(binding1 === binding2)
    }

    func test_refreshable_host_receives_updates_from_watched_viewModel() {
        let host = RefreshableHost()
        let spec = ViewModelSpec<CounterViewModel> { CounterViewModel() }

        let vm = host.viewModelBinding.watch(spec)
        vm.increment()
        vm.increment()

        XCTAssertEqual(host.updateCount, 2)
    }

    func test_binding_disposes_when_host_is_released() async {
        let spec = ViewModelSpec<CounterViewModel>(key: "object-host") { CounterViewModel() }
        var retainedViewModel: CounterViewModel?
        weak var weakHost: PlainHost?

        do {
            let host = PlainHost()
            weakHost = host
            retainedViewModel = host.viewModelBinding.watch(spec)
            XCTAssertFalse(retainedViewModel?.isDisposed ?? true)
        }

        XCTAssertNil(weakHost)

        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertTrue(retainedViewModel?.isDisposed ?? false)
    }
}

@MainActor
private final class RefreshableHost: NSObject, ViewModelBindingRefreshable {
    var updateCount: Int = 0

    func viewModelBindingDidUpdate() {
        updateCount += 1
    }
}

@MainActor
private final class PlainHost: NSObject {}
#endif
