#if canImport(SwiftUI)
import Combine
import SwiftUI
import XCTest
@testable import AppleViewModel

/// Intentionally has no Equatable conformance: callers supply domain equality.
private final class SelectorBusinessValue {
    let id: Int
    let text: String

    init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

private struct CustomSelectorState {
    let primary: SelectorBusinessValue
    let secondary: SelectorBusinessValue
}

@MainActor
final class CustomSelectorParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_nonEquatableSelectedValueUsesExplicitComparator() {
        ViewModel.initialize(config: ViewModelConfig(equals: { _, _ in true }))
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let initial = SelectorBusinessValue(id: 1, text: "initial")
        let spec = ViewModelSpec<StateViewModel<SelectorBusinessValue>> {
            StateViewModel(state: initial, equals: { $0 === $1 })
        }
        let viewModel = binding.read(spec)
        let equals: (SelectorBusinessValue, SelectorBusinessValue) -> Bool = {
            $0.id == $1.id
        }
        let view = StateViewModelSelector(
            viewModel: viewModel,
            selector: { $0 },
            equals: equals
        ) { Text($0.text) }
        let host = _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: { $0 },
            equals: equals
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        viewModel.setState(SelectorBusinessValue(id: 1, text: "same business identity"))
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(host.selected === initial)

        let changed = SelectorBusinessValue(id: 2, text: "changed")
        viewModel.setState(changed)
        XCTAssertEqual(refreshes, 1, "The explicit comparator takes precedence over global equality")
        XCTAssertTrue(host.selected === changed)
        withExtendedLifetime((view, cancellable)) {}
    }

    func test_nonEquatableHostUsesLatestSelectorAndComparator() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let first = SelectorBusinessValue(id: 1, text: "primary")
        let second = SelectorBusinessValue(id: 2, text: "secondary")
        let spec = ViewModelSpec<StateViewModel<CustomSelectorState>> {
            StateViewModel(
                state: CustomSelectorState(primary: first, secondary: second),
                equals: { _, _ in false }
            )
        }
        let viewModel = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: { $0.primary },
            equals: { $0.id == $1.id }
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        let selected = host.update(
            viewModel: viewModel,
            selector: { $0.secondary },
            equals: { $0.text == $1.text }
        )
        XCTAssertTrue(selected === second)
        viewModel.setState(CustomSelectorState(
            primary: SelectorBusinessValue(id: 3, text: "new primary"),
            secondary: SelectorBusinessValue(id: 99, text: "secondary")
        ))
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(host.selected === second)

        let changed = SelectorBusinessValue(id: 99, text: "new secondary")
        viewModel.setState(CustomSelectorState(primary: first, secondary: changed))
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(host.selected === changed)
        withExtendedLifetime(cancellable) {}
    }

    func test_nonEquatableHostFollowsRecycledGeneration() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var builds = 0
        let spec = ViewModelSpec<StateViewModel<SelectorBusinessValue>> {
            builds += 1
            return StateViewModel(
                state: SelectorBusinessValue(id: builds, text: "generation \(builds)"),
                equals: { $0 === $1 }
            )
        }
        let first = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: first,
            selector: { $0 },
            equals: { $0.id == $1.id }
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        binding.recycle(first)
        let second = binding.read(spec)
        let selected = host.update(
            viewModel: second,
            selector: { $0 },
            equals: { $0.id == $1.id }
        )
        XCTAssertTrue(first.isDisposed)
        XCTAssertFalse(first === second)
        XCTAssertTrue(selected === second.state)
        XCTAssertEqual(builds, 2)

        first.setState(SelectorBusinessValue(id: 100, text: "disposed"))
        XCTAssertEqual(refreshes, 0)
        let changed = SelectorBusinessValue(id: 3, text: "live")
        second.setState(changed)
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(host.selected === changed)
        withExtendedLifetime(cancellable) {}
    }

    func test_equatableOptionalComparatorStillRefreshesGlobalFallbackOnUpdate() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<CounterStateViewModel> { CounterStateViewModel() }
        let viewModel = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: { $0.label },
            equals: nil
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }
        viewModel.inc()
        XCTAssertEqual(refreshes, 0, "Equatable fallback suppresses the unchanged label before configuration")

        ViewModel.initialize(config: ViewModelConfig(equals: { _, _ in false }))
        _ = host.update(viewModel: viewModel, selector: { $0.label }, equals: nil)
        viewModel.inc()
        XCTAssertEqual(refreshes, 1)

        let view = StateViewModelSelector(viewModel: viewModel, selector: { $0.count }) {
            Text("\($0)")
        }
        withExtendedLifetime((view, cancellable)) {}
    }
}
#endif
