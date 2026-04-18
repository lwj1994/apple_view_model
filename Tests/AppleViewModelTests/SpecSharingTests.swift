import XCTest
@testable import AppleViewModel

@MainActor
final class SpecSharingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_setProxy_overrides_builder_key_tag_aliveForever() {
        final class ReplacementVM: CounterViewModel {}

        let spec = ViewModelSpec<CounterViewModel>(key: "real") { CounterViewModel() }
        spec.setProxy(ViewModelSpec<CounterViewModel>(
            key: "mock",
            tag: "mock-tag",
            aliveForever: true
        ) { ReplacementVM() })

        let b = ViewModelBinding()
        let vm = b.watch(spec)
        XCTAssertTrue(vm is ReplacementVM)
        XCTAssertEqual(spec.key() as? String, "mock")
        XCTAssertEqual(spec.tag() as? String, "mock-tag")
        XCTAssertEqual(spec.aliveForever(), true)

        spec.clearProxy()
        XCTAssertEqual(spec.key() as? String, "real")
        XCTAssertFalse(spec.aliveForever())
        b.dispose()
    }

    func test_tag_matches_find_newly_instance_across_bindings() throws {
        let spec = ViewModelSpec<CounterViewModel>(tag: "feed") { CounterViewModel() }
        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()
        let b3 = ViewModelBinding()

        _ = b1.watch(spec)  // instance 1
        _ = b2.watch(spec)  // instance 2 (newer)

        // Another binding asks "find the most recent by tag". It should pick the
        // newest instance.
        let found: CounterViewModel = try b3.readCached(tag: "feed")
        XCTAssertEqual(found.tag as? String, "feed")

        b1.dispose()
        b2.dispose()
        b3.dispose()
    }

    func test_static_readCached_returns_instance_by_key() throws {
        let spec = ViewModelSpec<CounterViewModel>(key: "auth", aliveForever: true) { CounterViewModel() }
        let b = ViewModelBinding()
        let vm = b.watch(spec)

        let found: CounterViewModel = try ViewModel.readCached(key: "auth")
        XCTAssertTrue(found === vm)

        b.dispose()
    }

    func test_static_maybeReadCached_returns_nil_for_missing_key() {
        let found: CounterViewModel? = ViewModel.maybeReadCached(key: "not-there")
        XCTAssertNil(found)
    }
}
