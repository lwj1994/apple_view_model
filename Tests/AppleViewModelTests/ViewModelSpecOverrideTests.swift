import XCTest
@testable import AppleViewModel

@MainActor
private final class OverrideLabelViewModel: ViewModel {
    let label: String

    init(_ label: String) {
        self.label = label
        super.init()
    }
}

@MainActor
private final class OverrideAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

@MainActor
final class ViewModelSpecOverrideTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    private func resolve(_ spec: ViewModelSpec<OverrideLabelViewModel>) -> String {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        return binding.read(spec).label
    }

    func test_overrideWith_isNestedIdempotentAndSupportsOutOfOrderRestore() {
        let base = ViewModelSpec { OverrideLabelViewModel("base") }
        let first = ViewModelSpec { OverrideLabelViewModel("first") }
        let second = ViewModelSpec { OverrideLabelViewModel("second") }

        let restoreFirst = base.overrideWith(first)
        let restoreSecond = base.overrideWith(second)
        XCTAssertEqual(resolve(base), "second")

        restoreFirst()
        XCTAssertEqual(resolve(base), "second")
        restoreFirst()

        restoreSecond()
        XCTAssertEqual(resolve(base), "base")
    }

    func test_scopedOverrideTakesPriorityOverLegacyAndCanClearKeyAndTag() {
        let base = ViewModelSpec<OverrideLabelViewModel>(
            key: "base-key",
            tag: "base-tag"
        ) { OverrideLabelViewModel("base") }
        let legacy = ViewModelSpec<OverrideLabelViewModel>(key: "legacy") {
            OverrideLabelViewModel("legacy")
        }
        let scoped = ViewModelSpec<OverrideLabelViewModel> {
            OverrideLabelViewModel("scoped")
        }

        base.setProxy(legacy)
        let restore = base.overrideWith(scoped)
        XCTAssertEqual(resolve(base), "scoped")
        XCTAssertNil(base.key())
        XCTAssertNil(base.tag())

        restore()
        XCTAssertEqual(resolve(base), "legacy")
        base.clearProxy()
        XCTAssertEqual(resolve(base), "base")
    }

    func test_runWithOverrideRestoresAfterFailureAndNestedScope() async {
        enum Expected: Error { case failure }

        let base = ViewModelSpec { OverrideLabelViewModel("base") }
        let outer = ViewModelSpec { OverrideLabelViewModel("outer") }
        let inner = ViewModelSpec { OverrideLabelViewModel("inner") }

        do {
            try await base.runWithOverride(outer) {
                XCTAssertEqual(self.resolve(base), "outer")
                try await base.runWithOverride(inner) {
                    await Task.yield()
                    XCTAssertEqual(self.resolve(base), "inner")
                    throw Expected.failure
                }
            }
            XCTFail("Expected the nested body to throw")
        } catch Expected.failure {
            XCTAssertEqual(resolve(base), "base")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_runWithOverrideIsolatesOverlappingAsyncBodies() async {
        let base = ViewModelSpec { OverrideLabelViewModel("base") }
        let first = ViewModelSpec { OverrideLabelViewModel("first") }
        let second = ViewModelSpec { OverrideLabelViewModel("second") }
        let firstEntered = OverrideAsyncGate()
        let secondEntered = OverrideAsyncGate()
        let releaseSecond = OverrideAsyncGate()

        let firstTask = Task { @MainActor in
            await base.runWithOverride(first) {
                firstEntered.open()
                await secondEntered.wait()
                let value = self.resolve(base)
                releaseSecond.open()
                return value
            }
        }
        let secondTask = Task { @MainActor in
            await base.runWithOverride(second) {
                await firstEntered.wait()
                secondEntered.open()
                await releaseSecond.wait()
                return self.resolve(base)
            }
        }

        let values = await (firstTask.value, secondTask.value)
        XCTAssertEqual(values.0, "first")
        XCTAssertEqual(values.1, "second")
        XCTAssertEqual(resolve(base), "base")
    }

    func test_overrideWithIsAvailableForArgOneThroughFour() {
        let arg1 = ViewModelSpecWithArg<OverrideLabelViewModel, String>(
            builder: { OverrideLabelViewModel("base-\($0)") }
        )
        let arg1Override = ViewModelSpecWithArg<OverrideLabelViewModel, String>(
            builder: { OverrideLabelViewModel("override-\($0)") }
        )
        let restore1 = arg1.overrideWith(arg1Override)
        XCTAssertEqual(resolve(arg1("a")), "override-a")
        restore1()

        let arg2 = ViewModelSpecWithArg2<OverrideLabelViewModel, String, Int>(
            builder: { OverrideLabelViewModel("\($0)-\($1)") }
        )
        let arg2Override = ViewModelSpecWithArg2<OverrideLabelViewModel, String, Int>(
            builder: { OverrideLabelViewModel("override-\($0)-\($1)") }
        )
        let restore2 = arg2.overrideWith(arg2Override)
        XCTAssertEqual(resolve(arg2("a", 2)), "override-a-2")
        restore2()

        let arg3 = ViewModelSpecWithArg3<OverrideLabelViewModel, String, Int, Bool>(
            builder: { OverrideLabelViewModel("\($0)-\($1)-\($2)") }
        )
        let arg3Override = ViewModelSpecWithArg3<OverrideLabelViewModel, String, Int, Bool>(
            builder: { OverrideLabelViewModel("override-\($0)-\($1)-\($2)") }
        )
        let restore3 = arg3.overrideWith(arg3Override)
        XCTAssertEqual(resolve(arg3("a", 3, true)), "override-a-3-true")
        restore3()

        let arg4 = ViewModelSpecWithArg4<OverrideLabelViewModel, String, Int, Bool, Double>(
            builder: { OverrideLabelViewModel("\($0)-\($1)-\($2)-\($3)") }
        )
        let arg4Override = ViewModelSpecWithArg4<OverrideLabelViewModel, String, Int, Bool, Double>(
            builder: { OverrideLabelViewModel("override-\($0)-\($1)-\($2)-\($3)") }
        )
        let restore4 = arg4.overrideWith(arg4Override)
        XCTAssertEqual(resolve(arg4("a", 4, true, 0.5)), "override-a-4-true-0.5")
        restore4()
    }
}
