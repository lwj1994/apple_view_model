import XCTest
@testable import AppleViewModel

@MainActor
final class ObservableValueTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_same_shareKey_shares_underlying_value() {
        let a = ObservableValue<Int>(initialValue: 1, shareKey: "counter")
        let b = ObservableValue<Int>(initialValue: 999, shareKey: "counter")

        XCTAssertEqual(a.value, 1)
        // The second init reuses the cached state, so its initialValue is ignored.
        XCTAssertEqual(b.value, 1)

        a.value = 42
        XCTAssertEqual(b.value, 42)
    }

    func test_different_shareKeys_are_independent() {
        let a = ObservableValue<Int>(initialValue: 1, shareKey: "a")
        let b = ObservableValue<Int>(initialValue: 2, shareKey: "b")

        a.value = 100
        XCTAssertEqual(a.value, 100)
        XCTAssertEqual(b.value, 2)
    }

    func test_no_shareKey_defaults_to_unique_local() {
        let a = ObservableValue<Int>(initialValue: 1)
        let b = ObservableValue<Int>(initialValue: 1)

        a.value = 5
        XCTAssertEqual(a.value, 5)
        XCTAssertEqual(b.value, 1, "without a shareKey each ObservableValue is private")
    }
}
