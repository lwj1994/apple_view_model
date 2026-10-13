#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AppleViewModel

@MainActor
private final class RenderRecorder {
    var values: [Int] = []
    var binding: HostedViewModelBinding?

    func text(_ value: Int) -> Text {
        values.append(value)
        return Text("\(value)")
    }
}

@MainActor
private struct WatchProbe: View {
    @WatchViewModel private var vm: CounterViewModel
    let recorder: RenderRecorder

    init(spec: ViewModelSpec<CounterViewModel>, recorder: RenderRecorder) {
        _vm = WatchViewModel(spec)
        self.recorder = recorder
    }

    var body: some View {
        recorder.binding = $vm
        return recorder.text(vm.count)
    }
}

@MainActor
private struct ReadProbe: View {
    @ReadViewModel private var vm: CounterViewModel
    let recorder: RenderRecorder

    init(spec: ViewModelSpec<CounterViewModel>, recorder: RenderRecorder) {
        _vm = ReadViewModel(spec)
        self.recorder = recorder
    }

    var body: some View {
        recorder.binding = $vm
        return recorder.text(vm.count)
    }
}

@MainActor
private final class MountedCoverageView {
    let view: NSHostingView<AnyView>
    let window: NSWindow

    init<Content: View>(_ content: Content) {
        view = NSHostingView(rootView: AnyView(content))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
    }

    func settle() async throws {
        // Let SwiftUI commit the invalidated graph on the main run loop.
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func unmount() {
        view.rootView = AnyView(EmptyView())
        view.layoutSubtreeIfNeeded()
        window.contentView = nil
        window.close()
    }
}

private enum RenderingCoverageError: Error { case lookup }

@MainActor
final class SwiftUIRenderingCoverageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_mountedWatchAndReadWrappersOwnInstancesButOnlyWatchRefreshes() async throws {
        let creator = ViewModelBinding()
        defer { creator.dispose() }
        let spec = ViewModelSpec<CounterViewModel>(key: "render-wrappers") { CounterViewModel() }
        let vm = creator.read(spec)
        let watched = RenderRecorder()
        let read = RenderRecorder()
        let mount = MountedCoverageView(VStack {
            WatchProbe(spec: spec, recorder: watched)
            ReadProbe(spec: spec, recorder: read)
        })
        defer {
            mount.unmount()
            watched.binding?.dispose()
            read.binding?.dispose()
        }
        try await mount.settle()
        XCTAssertEqual(watched.values.last, 0)
        XCTAssertEqual(read.values.last, 0)
        XCTAssertNotNil(watched.binding)
        XCTAssertNotNil(read.binding)
        let readCount = read.values.count
        creator.dispose()
        XCTAssertFalse(vm.isDisposed)
        vm.increment()
        try await mount.settle()
        XCTAssertEqual(watched.values.last, 1)
        XCTAssertEqual(read.values.count, readCount)
        mount.unmount()
        try await mount.settle()
        XCTAssertTrue(vm.isDisposed)
    }

    func test_mountedSelectorsAndValueWatcherRenderOnlySelectedChanges() async throws {
        struct Selection { let count: Int }
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let vm = owner.read(ViewModelSpec { CounterStateViewModel() })
        let typed = RenderRecorder()
        let custom = RenderRecorder()
        let legacy = RenderRecorder()
        let mount = MountedCoverageView(VStack {
            StateViewModelSelector(viewModel: vm, selector: { $0.count }) { typed.text($0) }
            StateViewModelSelector(
                viewModel: vm,
                selector: { Selection(count: $0.count) },
                equals: { $0.count == $1.count }
            ) { custom.text($0.count) }
            StateViewModelValueWatcher(viewModel: vm, selectors: [{ AnyHashable($0.count) }]) {
                legacy.text($0.count)
            }
        })
        defer { mount.unmount() }
        try await mount.settle()
        XCTAssertEqual(typed.values.last, 0)
        XCTAssertEqual(custom.values.last, 0)
        XCTAssertEqual(legacy.values.last, 0)
        let counts = [typed.values.count, custom.values.count, legacy.values.count]
        vm.setLabel("unselected")
        try await mount.settle()
        XCTAssertEqual([typed.values.count, custom.values.count, legacy.values.count], counts)
        vm.inc()
        try await mount.settle()
        XCTAssertEqual(typed.values.last, 1)
        XCTAssertEqual(custom.values.last, 1)
        XCTAssertEqual(legacy.values.last, 1)
    }

    func test_cachedBuilderRendersValueThenReportsMissingGeneration() async throws {
        let missing = expectation(description: "Cached builder reports missing instance")
        missing.assertForOverFulfill = false
        ViewModel.initialize(config: ViewModelConfig(onError: { error, type in
            XCTAssertTrue(error is ViewModelError)
            XCTAssertEqual(String(describing: type), "listener")
            missing.fulfill()
        }))
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let vm = owner.read(ViewModelSpec<CounterViewModel>(key: "render-cache") { CounterViewModel() })
        let recorder = RenderRecorder()
        let mount = MountedCoverageView(CachedViewModelBuilder<CounterViewModel, Text>(shareKey: "render-cache") {
            recorder.text($0.count)
        })
        defer { mount.unmount() }
        try await mount.settle()
        XCTAssertEqual(recorder.values.last, 0)
        vm.increment()
        try await mount.settle()
        XCTAssertEqual(recorder.values.last, 1)
        owner.recycle(vm)
        try await mount.settle()
        await fulfillment(of: [missing], timeout: 2)
        XCTAssertTrue(vm.isDisposed)
    }

    func test_cachedHostReportsUnexpectedErrorsAndRefreshesAfterKeySwitch() throws {
        let errors = expectation(description: "Unexpected lookup error is reported")
        ViewModel.initialize(config: ViewModelConfig(onError: { error, _ in
            XCTAssertTrue(error is RenderingCoverageError)
            errors.fulfill()
        }))
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let host = CachedViewModelHost<CounterViewModel>(shareKey: "late", tag: nil)
        defer { host.binding.dispose() }
        _ = owner.read(ViewModelSpec<CounterViewModel>(key: "late") { CounterViewModel() })
        host.binding.installDependencyHooks(
            attaching: { _, _ in throw RenderingCoverageError.lookup },
            attached: { _, _ in nil }, detached: { _, _ in nil }, updated: { _ in }
        )
        XCTAssertNil(host.viewModel)
        wait(for: [errors], timeout: 1)

        let next = owner.read(ViewModelSpec<CounterViewModel>(key: "next") { CounterViewModel() })
        let previousBinding = host.binding
        XCTAssertTrue(host.update(shareKey: "next", tag: nil) === next)
        XCTAssertTrue(host.update(shareKey: "next", tag: nil) === next)
        var changes = 0
        let subscription = host.objectWillChange.sink { changes += 1 }
        previousBinding.refresh()
        XCTAssertEqual(changes, 0)
        next.increment()
        XCTAssertEqual(changes, 1)
        subscription.cancel()
    }

    func test_viewModelHostRefreshesNewBindingAndSilencesOldBinding() {
        let first = ViewModelSpec<CounterViewModel>(key: "first") { CounterViewModel() }
        let second = ViewModelSpec<CounterViewModel>(key: "second") { CounterViewModel() }
        let host = ViewModelHost(factory: first, listen: true)
        defer { host.binding.dispose() }
        let oldBinding = host.binding
        let next = host.update(factory: second)
        var changes = 0
        let subscription = host.objectWillChange.sink { changes += 1 }
        oldBinding.refresh()
        XCTAssertEqual(changes, 0)
        next.increment()
        XCTAssertEqual(changes, 1)
        subscription.cancel()
    }

    func test_valueWatcherRebindsGenerationAndUsesGlobalEquality() {
        ViewModel.initialize(config: ViewModelConfig(equals: { previous, current in
            (previous as? AnyHashable) == (current as? AnyHashable)
        }))
        let owner = ViewModelBinding()
        defer { owner.dispose() }
        let spec = ViewModelSpec { CounterStateViewModel() }
        let first = owner.read(spec)
        let host = _ValueWatcherHost(viewModel: first, selectors: [{ AnyHashable($0.count) }])
        owner.recycle(first)
        let second = owner.read(spec)
        XCTAssertEqual(host.update(viewModel: second, selectors: [{ AnyHashable($0.count) }]).count, 0)
        var changes = 0
        let subscription = host.objectWillChange.sink { changes += 1 }
        second.setLabel("ignored")
        XCTAssertEqual(changes, 0)
        second.inc()
        XCTAssertEqual(changes, 1)
        subscription.cancel()
    }
}
#endif
