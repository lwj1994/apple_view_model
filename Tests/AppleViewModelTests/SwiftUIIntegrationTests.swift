#if canImport(SwiftUI)
import Combine
import XCTest
@testable import AppleViewModel

@MainActor
private final class SwiftUIHostViewModel: ViewModel {
    let generation: Int

    init(generation: Int) {
        self.generation = generation
        super.init()
    }
}

private struct SwiftUISelectorState: Equatable {
    var count: Int
    var label: String
}

@MainActor
private final class SwiftUISelectorViewModel: StateViewModel<SwiftUISelectorState> {
    init() {
        super.init(
            state: SwiftUISelectorState(count: 0, label: "initial"),
            equals: { $0 == $1 }
        )
    }

    func set(count: Int? = nil, label: String? = nil) {
        setState(SwiftUISelectorState(
            count: count ?? state.count,
            label: label ?? state.label
        ))
    }
}

@MainActor
final class SwiftUIIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_viewModelHostReResolvesAfterRecycleInWatchAndReadModes() {
        for listen in [true, false] {
            var builds = 0
            let spec = ViewModelSpec<SwiftUIHostViewModel> {
                builds += 1
                return SwiftUIHostViewModel(generation: builds)
            }
            let host = ViewModelHost(factory: spec, listen: listen)
            var refreshes = 0
            let cancellable = host.objectWillChange.sink { refreshes += 1 }
            let old = host.viewModel

            host.binding.recycle(old)
            let current = host.viewModel

            XCTAssertTrue(old.isDisposed)
            XCTAssertFalse(current.isDisposed)
            XCTAssertFalse(old === current)
            XCTAssertEqual(current.generation, 2)
            XCTAssertEqual(builds, 2)
            XCTAssertGreaterThanOrEqual(refreshes, 1)
            withExtendedLifetime(cancellable) {}
            host.binding.dispose()
        }
    }

    func test_viewModelHostSwitchesBindingWhenConfiguredKeyChanges() {
        for listen in [true, false] {
            let firstSpec = ViewModelSpec<SwiftUIHostViewModel>(
                key: "swiftui-host-\(listen)-first"
            ) {
                SwiftUIHostViewModel(generation: 1)
            }
            let secondSpec = ViewModelSpec<SwiftUIHostViewModel>(
                key: "swiftui-host-\(listen)-second"
            ) {
                SwiftUIHostViewModel(generation: 2)
            }
            let host = ViewModelHost(factory: firstSpec, listen: listen)
            let initialBinding = host.binding
            let first = host.viewModel

            let second = host.update(factory: secondSpec)

            XCTAssertTrue(initialBinding.isDisposed)
            XCTAssertFalse(host.binding === initialBinding)
            XCTAssertTrue(first.isDisposed)
            XCTAssertFalse(second.isDisposed)
            XCTAssertFalse(first === second)
            XCTAssertEqual(second.generation, 2)
            host.binding.dispose()
        }
    }

    func test_viewModelHostKeepsIdentityButUsesLatestFactoryAfterRecycle() {
        let configuredKeys: [AnyHashable?] = [
            nil,
            AnyHashable("swiftui-host-stable-key")
        ]

        for configuredKey in configuredKeys {
            var initialBuilds = 0
            var updatedBuilds = 0
            let initialSpec = ViewModelSpec<SwiftUIHostViewModel>(key: configuredKey) {
                initialBuilds += 1
                return SwiftUIHostViewModel(generation: initialBuilds)
            }
            let updatedSpec = ViewModelSpec<SwiftUIHostViewModel>(key: configuredKey) {
                updatedBuilds += 1
                return SwiftUIHostViewModel(generation: 100 + updatedBuilds)
            }
            let host = ViewModelHost(factory: initialSpec, listen: true)
            let initialBinding = host.binding
            let first = host.viewModel

            let unchanged = host.update(factory: updatedSpec)

            XCTAssertTrue(unchanged === first)
            XCTAssertTrue(host.binding === initialBinding)
            XCTAssertEqual(initialBuilds, 1)
            XCTAssertEqual(updatedBuilds, 0)

            host.binding.recycle(first)
            let current = host.viewModel

            XCTAssertTrue(host.binding === initialBinding)
            XCTAssertFalse(current === first)
            XCTAssertEqual(current.generation, 101)
            XCTAssertEqual(initialBuilds, 1)
            XCTAssertEqual(updatedBuilds, 1)
            host.binding.dispose()
        }
    }

    func test_cachedHostBecomesNilAfterRecycleAndFindsLaterGeneration() throws {
        var builds = 0
        let spec = ViewModelSpec<SwiftUIHostViewModel>(key: "swiftui-cached") {
            builds += 1
            return SwiftUIHostViewModel(generation: builds)
        }
        let creator = ViewModelBinding()
        defer { creator.dispose() }
        let first = creator.read(spec)
        let host = CachedViewModelHost<SwiftUIHostViewModel>(
            shareKey: "swiftui-cached",
            tag: nil
        )
        defer { host.binding.dispose() }
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        XCTAssertTrue(try XCTUnwrap(host.viewModel) === first)
        creator.recycle(first)

        XCTAssertTrue(first.isDisposed)
        XCTAssertNil(host.viewModel)
        XCTAssertGreaterThanOrEqual(refreshes, 1)

        let second = creator.read(spec)
        XCTAssertFalse(second === first)
        XCTAssertTrue(try XCTUnwrap(host.viewModel) === second)
        XCTAssertEqual(second.generation, 2)
        withExtendedLifetime(cancellable) {}
    }

    func test_cachedHostUpdatesLookupAndReleasesPreviousOwner() throws {
        let creator = ViewModelBinding()
        defer { creator.dispose() }
        let firstSpec = ViewModelSpec<CounterViewModel>(
            key: "swiftui-cached-first",
            tag: "swiftui-cached-first-tag"
        ) {
            CounterViewModel()
        }
        let secondSpec = ViewModelSpec<CounterViewModel>(
            key: "swiftui-cached-second",
            tag: "swiftui-cached-second-tag"
        ) {
            CounterViewModel()
        }
        let first = creator.read(firstSpec)
        let second = creator.read(secondSpec)
        let host = CachedViewModelHost<CounterViewModel>(
            shareKey: "swiftui-cached-first",
            tag: nil
        )
        defer { host.binding.dispose() }
        let initialBinding = host.binding

        XCTAssertTrue(try XCTUnwrap(host.viewModel) === first)
        XCTAssertEqual(first.onBindCalls, 2)
        XCTAssertEqual(first.onUnbindCalls, 0)

        let updated = host.update(
            shareKey: nil,
            tag: "swiftui-cached-second-tag"
        )

        XCTAssertTrue(try XCTUnwrap(updated) === second)
        XCTAssertTrue(initialBinding.isDisposed)
        XCTAssertFalse(host.binding === initialBinding)
        XCTAssertEqual(first.onUnbindCalls, 1)
        XCTAssertFalse(first.isDisposed)
        XCTAssertEqual(second.onBindCalls, 2)
        XCTAssertTrue(
            CachedViewModelHost<CounterViewModel>.missingErrorMessage(
                shareKey: "missing",
                tag: "fallback"
            ).contains("shareKey=")
        )
    }

    func test_cachedHostKeySwitchDisposesSoleOwnedOldInstanceWithoutPublishing() throws {
        let firstCreator = ViewModelBinding()
        let secondCreator = ViewModelBinding()
        defer { secondCreator.dispose() }
        let firstSpec = ViewModelSpec<CounterViewModel>(key: "swiftui-cached-sole-first") {
            CounterViewModel()
        }
        let secondSpec = ViewModelSpec<CounterViewModel>(key: "swiftui-cached-sole-second") {
            CounterViewModel()
        }
        let first = firstCreator.read(firstSpec)
        let second = secondCreator.read(secondSpec)
        let host = CachedViewModelHost<CounterViewModel>(
            shareKey: "swiftui-cached-sole-first",
            tag: nil
        )
        defer { host.binding.dispose() }
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        firstCreator.dispose()
        XCTAssertFalse(first.isDisposed)

        let updated = host.update(
            shareKey: "swiftui-cached-sole-second",
            tag: nil
        )

        XCTAssertTrue(try XCTUnwrap(updated) === second)
        XCTAssertTrue(first.isDisposed)
        XCTAssertEqual(first.onUnbindCalls, 2)
        XCTAssertEqual(refreshes, 0)
        withExtendedLifetime(cancellable) {}
    }

    func test_typedStateSelectorTracksOnlyItsSelectedValue() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<SwiftUISelectorViewModel> {
            SwiftUISelectorViewModel()
        }
        let viewModel = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: { $0.label },
            equals: nil
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        XCTAssertEqual(host.selected, "initial")
        viewModel.set(count: 1)
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(host.selected, "initial")

        viewModel.set(label: "updated")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(host.selected, "updated")
        withExtendedLifetime(cancellable) {}
    }

    func test_typedStateSelectorUsesLatestSelectorAndEquals() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<SwiftUISelectorViewModel> {
            SwiftUISelectorViewModel()
        }
        let viewModel = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: viewModel,
            selector: { $0.count },
            equals: { _, _ in true }
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        let selected = host.update(
            viewModel: viewModel,
            selector: { $0.label.count },
            equals: { $0 == $1 }
        )

        XCTAssertEqual(selected, "initial".count)
        XCTAssertEqual(host.selected, "initial".count)

        viewModel.set(count: 1)
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(host.selected, "initial".count)

        viewModel.set(label: "next")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(host.selected, "next".count)
        withExtendedLifetime(cancellable) {}
    }

    func test_typedStateSelectorResubscribesToRecycledGeneration() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        var builds = 0
        let spec = ViewModelSpec<SwiftUISelectorViewModel> {
            builds += 1
            return SwiftUISelectorViewModel()
        }
        let first = binding.read(spec)
        let host = _StateViewModelSelectorHost(
            viewModel: first,
            selector: { $0.count },
            equals: nil
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        binding.recycle(first)
        let second = binding.read(spec)
        let selected = host.update(
            viewModel: second,
            selector: { $0.count },
            equals: nil
        )

        XCTAssertTrue(first.isDisposed)
        XCTAssertFalse(first === second)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(selected, 0)

        second.set(count: 1)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(host.selected, 1)
        withExtendedLifetime(cancellable) {}
    }

    func test_valueWatcherUsesLatestSelectors() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let spec = ViewModelSpec<SwiftUISelectorViewModel> {
            SwiftUISelectorViewModel()
        }
        let viewModel = binding.read(spec)
        let host = _ValueWatcherHost(
            viewModel: viewModel,
            selectors: [{ AnyHashable($0.count) }]
        )
        var refreshes = 0
        let cancellable = host.objectWillChange.sink { refreshes += 1 }

        viewModel.set(label: "before-update")
        XCTAssertEqual(refreshes, 0)

        _ = host.update(
            viewModel: viewModel,
            selectors: [{ AnyHashable($0.label) }]
        )
        viewModel.set(count: 1)
        XCTAssertEqual(refreshes, 0)

        viewModel.set(label: "after-update")
        XCTAssertEqual(refreshes, 1)
        withExtendedLifetime(cancellable) {}
    }
}
#endif
