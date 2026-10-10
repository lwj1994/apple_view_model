import XCTest
@testable import AppleViewModel

private enum NestedCreationPhase: CaseIterable {
    case initializer
    case onCreate
    case onBind
}

@MainActor
private final class NestedCreationViewModel: ViewModel {
    private let nestedSpec: ViewModelSpec<NestedCreationViewModel>?
    private let phase: NestedCreationPhase

    init(
        nestedSpec: ViewModelSpec<NestedCreationViewModel>? = nil,
        phase: NestedCreationPhase = .onCreate
    ) {
        self.nestedSpec = nestedSpec
        self.phase = phase
        super.init()
        if phase == .initializer { resolveNestedIfConfigured() }
    }

    override func onCreate(_ arg: InstanceArg) {
        super.onCreate(arg)
        if phase == .onCreate { resolveNestedIfConfigured() }
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        if phase == .onBind { resolveNestedIfConfigured() }
    }

    private func resolveNestedIfConfigured() {
        if let nestedSpec { _ = viewModelBinding.read(nestedSpec) }
    }
}

@MainActor
final class NestedCreationOrderingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_nestedCreationReservesDistinctIndicesBeforeLifecycleCallbacks() throws {
        for phase in NestedCreationPhase.allCases {
            let binding = ViewModelBinding()
            defer { binding.dispose() }
            let nestedSpec = ViewModelSpec<NestedCreationViewModel>(
                key: "nested", tag: "shared"
            ) { NestedCreationViewModel() }
            let outerSpec = ViewModelSpec<NestedCreationViewModel>(
                key: "outer", tag: "shared"
            ) { NestedCreationViewModel(nestedSpec: nestedSpec, phase: phase) }

            let outer = binding.read(outerSpec)
            let nested = outer.viewModelBinding.read(nestedSpec)
            let outerHandle = try InstanceManager.shared.getHandle(
                NestedCreationViewModel.self,
                factory: InstanceFactory(arg: InstanceArg(key: "outer"))
            )
            let nestedHandle = try InstanceManager.shared.getHandle(
                NestedCreationViewModel.self,
                factory: InstanceFactory(arg: InstanceArg(key: "nested"))
            )

            // A constructor child finishes before the outer handle exists.
            // An onCreate/onBind child begins after the outer index is reserved.
            let expectedLatest = phase == .initializer ? outer : nested
            let expectedOlder = phase == .initializer ? nested : outer
            if phase == .initializer {
                XCTAssertLessThan(nestedHandle.index, outerHandle.index)
            } else {
                XCTAssertLessThan(outerHandle.index, nestedHandle.index)
            }
            let latest: NestedCreationViewModel = try ViewModel.readCached()
            let tagged: NestedCreationViewModel = try ViewModel.readCached(tag: "shared")
            let batch = try InstanceManager.shared.getHandles(
                byTag: "shared", type: NestedCreationViewModel.self
            )
            XCTAssertTrue(latest === expectedLatest)
            XCTAssertTrue(tagged === expectedLatest)
            XCTAssertEqual(
                try batch.map { ObjectIdentifier(try $0.requireInstance()) },
                [expectedLatest, expectedOlder].map(ObjectIdentifier.init)
            )
        }
    }

    func test_recyclingNestedNewestFallsBackAndItsReplacementGetsANewerIndex() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let nestedSpec = ViewModelSpec<NestedCreationViewModel>(key: "nested") {
            NestedCreationViewModel()
        }
        let outerSpec = ViewModelSpec<NestedCreationViewModel>(key: "outer") {
            NestedCreationViewModel(nestedSpec: nestedSpec)
        }
        let outer = binding.read(outerSpec)
        let nested = outer.viewModelBinding.read(nestedSpec)
        let oldHandle = try InstanceManager.shared.getHandle(
            NestedCreationViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "nested"))
        )

        binding.recycle(nested)
        let fallback: NestedCreationViewModel = try ViewModel.readCached()
        XCTAssertTrue(fallback === outer)
        let replacement = outer.viewModelBinding.read(nestedSpec)
        let replacementHandle = try InstanceManager.shared.getHandle(
            NestedCreationViewModel.self,
            factory: InstanceFactory(arg: InstanceArg(key: "nested"))
        )
        let latest: NestedCreationViewModel = try ViewModel.readCached()
        XCTAssertFalse(replacement === nested)
        XCTAssertTrue(latest === replacement)
        XCTAssertGreaterThan(replacementHandle.index, oldHandle.index)
    }
}
