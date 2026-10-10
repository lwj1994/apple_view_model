import Foundation
import XCTest
@testable import AppleViewModel

@MainActor
private final class OrderedLookupViewModel: CounterViewModel {
    var unbindAction: (() -> Void)?

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        let action = unbindAction
        unbindAction = nil
        action?()
    }
}

@MainActor
private final class OtherOrderedLookupViewModel: ViewModel {}

private final class LookupTagHashProbe {
    var calls = 0
}

private final class LookupReferenceTag: Hashable {
    let value: String
    let probe: LookupTagHashProbe

    init(_ value: String, probe: LookupTagHashProbe) {
        self.value = value
        self.probe = probe
    }

    static func == (lhs: LookupReferenceTag, rhs: LookupReferenceTag) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        probe.calls += 1
        hasher.combine(value)
    }
}

private struct LookupValueTag: Hashable {
    let value: String
    let probe: LookupTagHashProbe

    static func == (lhs: LookupValueTag, rhs: LookupValueTag) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        probe.calls += 1
        hasher.combine(value)
    }
}

@MainActor
final class CachedLookupOrderingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_unfilteredCachedLookupsUseCreationOrderAndFallBackAfterRecycle() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        #if DEBUG
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        #endif
        let olderSpec = spec(key: "older")
        let newerSpec = spec(key: "newer")
        let older = binding.read(olderSpec)
        let first: OrderedLookupViewModel = try ViewModel.readCached()
        XCTAssertTrue(first === older)

        let newer = binding.read(newerSpec)
        XCTAssertTrue(binding.read(olderSpec) === older)
        let olderByKey: OrderedLookupViewModel = try binding.readCached(key: "older")
        XCTAssertTrue(olderByKey === older)

        let staticRead: OrderedLookupViewModel = try ViewModel.readCached()
        let staticMaybe: OrderedLookupViewModel? = ViewModel.maybeReadCached()
        let boundRead: OrderedLookupViewModel = try binding.readCached()
        let boundMaybeRead: OrderedLookupViewModel? = binding.maybeReadCached()
        let boundWatch: OrderedLookupViewModel = try binding.watchCached()
        let boundMaybeWatch: OrderedLookupViewModel? = binding.maybeWatchCached()
        XCTAssertTrue(staticRead === newer)
        XCTAssertTrue(staticMaybe === newer)
        XCTAssertTrue(boundRead === newer)
        XCTAssertTrue(boundMaybeRead === newer)
        XCTAssertTrue(boundWatch === newer)
        XCTAssertTrue(boundMaybeWatch === newer)

        binding.recycle(newer)
        let staticFallback: OrderedLookupViewModel = try ViewModel.readCached()
        let boundFallback: OrderedLookupViewModel = try binding.readCached()
        XCTAssertTrue(staticFallback === older)
        XCTAssertTrue(boundFallback === older)

        let recreated = binding.read(newerSpec)
        let latest: OrderedLookupViewModel = try binding.readCached()
        XCTAssertFalse(recreated === newer)
        XCTAssertTrue(latest === recreated)
        #if DEBUG
        XCTAssertTrue(warnings.isEmpty)
        #endif
    }

    func test_tagLookupSelectsNewestMatchingCreationAndBatchKeepsNewestFirst() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let oldestSpec = spec(key: "oldest", tag: "shared")
        let middleSpec = spec(key: "middle", tag: "shared")
        let newestSpec = spec(key: "newest", tag: "shared")
        let oldest = binding.read(oldestSpec)
        let middle = binding.read(middleSpec)
        let newest = binding.read(newestSpec)
        let other = binding.read(spec(key: "other", tag: "other"))
        XCTAssertTrue(binding.read(oldestSpec) === oldest)

        let tagged: OrderedLookupViewModel = try ViewModel.readCached(tag: "shared")
        let unfiltered: OrderedLookupViewModel = try ViewModel.readCached()
        XCTAssertTrue(tagged === newest)
        XCTAssertTrue(unfiltered === other)
        let batch: [OrderedLookupViewModel] = try binding.readCachesByTagThrowing("shared")
        XCTAssertEqual(batch.map(ObjectIdentifier.init), [newest, middle, oldest].map(ObjectIdentifier.init))

        binding.recycle(newest)
        let fallback: OrderedLookupViewModel = try binding.watchCached(tag: "shared")
        XCTAssertTrue(fallback === middle)
    }

    func test_storeCountsLiveHandlesWithoutCountingCacheHits() throws {
        let store = Store<NSObject>()
        defer { store.dispose() }
        func resolve(_ key: String, tag: AnyHashable? = nil) throws -> InstanceHandle<NSObject> {
            try store.getHandle(factory: InstanceFactory(
                builder: { NSObject() },
                arg: InstanceArg(key: key, tag: tag)
            ))
        }

        XCTAssertEqual(store.countInstances(), 0)
        XCTAssertEqual(store.countInstances(tag: "shared"), 0)
        let first = try resolve("first", tag: "shared")
        let untagged = try resolve("untagged")
        let second = try resolve("second", tag: "shared")
        XCTAssertEqual(store.countInstances(), 3)
        XCTAssertEqual(store.countInstances(tag: "shared"), 2)
        XCTAssertEqual(store.countInstances(tag: "missing"), 0)
        XCTAssertTrue(try resolve("first", tag: "shared") === first)
        XCTAssertEqual(store.countInstances(), 3)
        XCTAssertEqual(store.countInstances(tag: "shared"), 2)

        XCTAssertTrue(store.tryRecycle(try second.requireInstance()))
        XCTAssertEqual(store.countInstances(), 2)
        XCTAssertEqual(store.countInstances(tag: "shared"), 1)
        XCTAssertTrue(store.tryRecycle(try untagged.requireInstance()))
        XCTAssertEqual(store.countInstances(), 1)
        XCTAssertEqual(store.countInstances(tag: "shared"), 1)
        XCTAssertTrue(store.tryRecycle(try first.requireInstance()))
        XCTAssertEqual(store.countInstances(), 0)
        XCTAssertEqual(store.countInstances(tag: "shared"), 0)
        store.dispose()
        XCTAssertEqual(store.countInstances(), 0)
    }

    func test_countsAndWarningsExcludeHandleAlreadyBeingDisposed() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        #if DEBUG
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        #endif
        let older = binding.read(spec(key: "older", tag: "shared"))
        let newer = binding.read(spec(key: "newer", tag: "shared"))
        let store = InstanceManager.shared.store(for: OrderedLookupViewModel.self)
        var callbacks = 0
        newer.unbindAction = {
            callbacks += 1
            XCTAssertEqual(store.countInstances(), 1)
            XCTAssertEqual(store.countInstances(tag: "shared"), 1)
            let found: OrderedLookupViewModel? = ViewModel.maybeReadCached(tag: "shared")
            XCTAssertTrue(found === older)
        }

        binding.recycle(newer)

        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(newer.isDisposed)
        XCTAssertEqual(store.countInstances(), 1)
        #if DEBUG
        XCTAssertTrue(warnings.isEmpty)
        #endif
    }

    #if DEBUG
    func test_onlyAmbiguousSingleTagLookupsWarnAndShareDeduplicationAcrossAPIs() throws {
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let olderSpec = spec(key: "older", tag: "shared")
        let newerSpec = spec(key: "newer", tag: "shared")
        let older = binding.read(olderSpec)
        let only: OrderedLookupViewModel = try binding.readCached(tag: "shared")
        XCTAssertTrue(only === older)
        XCTAssertTrue(warnings.isEmpty)

        let newer = binding.read(newerSpec)
        XCTAssertTrue(binding.watch(olderSpec) === older)
        let byKey: OrderedLookupViewModel = try binding.readCached(key: "older", tag: "shared")
        XCTAssertTrue(byKey === older)
        let batch: [OrderedLookupViewModel] = try binding.readCachesByTagThrowing("shared")
        XCTAssertEqual(batch.count, 2)
        XCTAssertTrue(warnings.isEmpty)

        let read: OrderedLookupViewModel = try binding.readCached(tag: "shared")
        let watch: OrderedLookupViewModel = try binding.watchCached(tag: "shared")
        let staticRead: OrderedLookupViewModel = try ViewModel.readCached(tag: "shared")
        let maybeRead: OrderedLookupViewModel? = ViewModel.maybeReadCached(tag: "shared")
        let maybeBoundRead: OrderedLookupViewModel? = binding.maybeReadCached(tag: "shared")
        let maybeBoundWatch: OrderedLookupViewModel? = binding.maybeWatchCached(tag: "shared")
        XCTAssertTrue(read === newer)
        XCTAssertTrue(watch === newer)
        XCTAssertTrue(staticRead === newer)
        XCTAssertTrue(maybeRead === newer)
        XCTAssertTrue(maybeBoundRead === newer)
        XCTAssertTrue(maybeBoundWatch === newer)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("matched 2 instances") == true)
        XCTAssertTrue(warnings.first?.contains("OrderedLookupViewModel") == true)
        XCTAssertTrue(warnings.first?.contains("readCachesByTag/watchCachesByTag") == true)
    }

    func test_referenceTagsMatchByEqualityButWarnByObjectIdentityWithoutHashing() throws {
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let probe = LookupTagHashProbe()
        _ = binding.read(spec(key: "older", tag: AnyHashable(LookupReferenceTag("shared", probe: probe))))
        let newest = binding.read(spec(key: "newest", tag: AnyHashable(LookupReferenceTag("shared", probe: probe))))
        let queryTag = LookupReferenceTag("shared", probe: probe)
        let equalTag = LookupReferenceTag("shared", probe: probe)
        probe.calls = 0

        for _ in 0..<3 {
            let found: OrderedLookupViewModel = try ViewModel.readCached(tag: AnyHashable(queryTag))
            let bound: OrderedLookupViewModel = try binding.watchCached(tag: AnyHashable(queryTag))
            XCTAssertTrue(found === newest)
            XCTAssertTrue(bound === newest)
        }
        XCTAssertEqual(warnings.count, 1)

        for _ in 0..<2 {
            let found: OrderedLookupViewModel = try binding.readCached(tag: AnyHashable(equalTag))
            XCTAssertTrue(found === newest)
        }
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(probe.calls, 0)
    }

    func test_valueTagsDeduplicateByEqualityWithoutHashingAndRemainScopedByType() throws {
        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let probe = LookupTagHashProbe()
        let tag = LookupValueTag(value: "shared", probe: probe)
        _ = binding.read(spec(key: "older", tag: AnyHashable(tag)))
        let newest = binding.read(spec(key: "newest", tag: AnyHashable(tag)))
        for key in ["older", "newest"] {
            _ = binding.read(ViewModelSpec<OtherOrderedLookupViewModel>(key: key, tag: AnyHashable(tag)) {
                OtherOrderedLookupViewModel()
            })
        }
        probe.calls = 0

        for _ in 0..<3 {
            let equalTag = LookupValueTag(value: "shared", probe: probe)
            let found: OrderedLookupViewModel = try ViewModel.readCached(tag: AnyHashable(equalTag))
            XCTAssertTrue(found === newest)
        }
        XCTAssertEqual(warnings.count, 1)
        let _: OtherOrderedLookupViewModel = try ViewModel.readCached(tag: AnyHashable(tag))
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(probe.calls, 0)
    }

    func test_loggingDisabledDoesNotConsumeLaterTagWarning() throws {
        var warnings: [String] = []
        InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
        defer { InstanceManager.shared.debugTagLookupWarningHandler = { viewModelLog($0) } }
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        _ = binding.read(spec(key: "older", tag: "shared"))
        _ = binding.read(spec(key: "newer", tag: "shared"))
        let _: OrderedLookupViewModel = try ViewModel.readCached(tag: "shared")
        XCTAssertTrue(warnings.isEmpty)

        ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
        let _: OrderedLookupViewModel = try ViewModel.readCached(tag: "shared")
        XCTAssertEqual(warnings.count, 1)
    }

    func test_resetClearsTagWarningDeduplication() throws {
        var warnings: [String] = []
        for iteration in 1...2 {
            ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
            InstanceManager.shared.debugTagLookupWarningHandler = { warnings.append($0) }
            let binding = ViewModelBinding()
            defer { binding.dispose() }
            _ = binding.read(spec(key: "older", tag: "shared"))
            _ = binding.read(spec(key: "newer", tag: "shared"))
            let _: OrderedLookupViewModel = try ViewModel.readCached(tag: "shared")
            let _: OrderedLookupViewModel = try binding.readCached(tag: "shared")
            XCTAssertEqual(warnings.count, iteration)
            ViewModel.reset()
            XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
        }
    }
    #endif

    private func spec(key: String, tag: AnyHashable? = nil) -> ViewModelSpec<OrderedLookupViewModel> {
        ViewModelSpec(key: key, tag: tag) { OrderedLookupViewModel() }
    }
}
