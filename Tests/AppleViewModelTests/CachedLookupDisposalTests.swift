import XCTest
@testable import AppleViewModel

@MainActor
private final class CachedLookupDisposalViewModel: CounterViewModel {
    var unbindAction: ((CachedLookupDisposalViewModel) -> Void)?

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        let action = unbindAction
        unbindAction = nil
        action?(self)
    }
}

@MainActor
final class CachedLookupDisposalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_bindingTagLookupSelectsNewestLiveMatchDuringDisposal() {
        withDisposingNewest { reader, newestLive, _, _ in
            let found: CachedLookupDisposalViewModel = try reader.readCached(tag: "shared")
            XCTAssertTrue(found === newestLive)
        }
    }

    func test_staticTagLookupSelectsNewestLiveMatchDuringDisposal() {
        withDisposingNewest { _, newestLive, _, _ in
            let found: CachedLookupDisposalViewModel = try ViewModel.readCached(tag: "shared")
            XCTAssertTrue(found === newestLive)
        }
    }

    func test_latestLookupWithoutTagSkipsDisposingHandle() {
        withDisposingNewest { reader, newestLive, _, _ in
            let bound: CachedLookupDisposalViewModel = try reader.readCached()
            let unbound: CachedLookupDisposalViewModel = try ViewModel.readCached()
            XCTAssertTrue(bound === newestLive)
            XCTAssertTrue(unbound === newestLive)
        }
    }

    func test_keyAndTagFallbackSkipsDisposingHandle() {
        withDisposingNewest { reader, newestLive, _, _ in
            // Exact-key queries must not silently select a different identity.
            XCTAssertThrowsError(
                try reader.readCached(key: "disposing") as CachedLookupDisposalViewModel
            )
            XCTAssertThrowsError(
                try ViewModel.readCached(key: "disposing") as CachedLookupDisposalViewModel
            )
            for key in ["disposing", "missing"] {
                let bound: CachedLookupDisposalViewModel = try reader.readCached(
                    key: key, tag: "shared"
                )
                let unbound: CachedLookupDisposalViewModel = try ViewModel.readCached(
                    key: key, tag: "shared"
                )
                XCTAssertTrue(bound === newestLive)
                XCTAssertTrue(unbound === newestLive)
            }
        }
    }

    func test_readTagBatchSkipsDisposingHandleAndKeepsNewestFirst() {
        withDisposingNewest { reader, newestLive, oldestLive, _ in
            let matches: [CachedLookupDisposalViewModel] = try reader.readCachesByTagThrowing(
                "shared"
            )
            XCTAssertEqual(
                matches.map { ObjectIdentifier($0) },
                [newestLive, oldestLive].map { ObjectIdentifier($0) }
            )
            var updates = 0
            reader.refresh = { updates += 1 }
            newestLive.increment()
            oldestLive.increment()
            XCTAssertEqual(updates, 0)
        }
    }

    func test_watchTagBatchSkipsDisposingHandleAndSubscribesToLiveMatches() {
        withDisposingNewest { reader, newestLive, oldestLive, _ in
            let matches: [CachedLookupDisposalViewModel] = try reader.watchCachesByTagThrowing(
                "shared"
            )
            XCTAssertEqual(
                matches.map { ObjectIdentifier($0) },
                [newestLive, oldestLive].map { ObjectIdentifier($0) }
            )
            var updates = 0
            reader.refresh = { updates += 1 }
            newestLive.increment()
            oldestLive.increment()
            XCTAssertEqual(updates, 2)
        }
    }

    func test_watchLookupSubscribesToLiveFallbackWithoutDuplicateListeners() {
        withDisposingNewest { reader, newestLive, _, _ in
            var updates = 0
            reader.refresh = { updates += 1 }
            let tagged: CachedLookupDisposalViewModel = try reader.watchCached(tag: "shared")
            XCTAssertTrue(tagged === newestLive)
            tagged.increment()
            XCTAssertEqual(updates, 1)

            let latest: CachedLookupDisposalViewModel = try reader.watchCached()
            XCTAssertTrue(latest === newestLive)
            latest.increment()
            XCTAssertEqual(updates, 2)
        }
    }

    func test_noLiveTagMatchReturnsMissOrEmptyBatchDuringDisposal() {
        let owner = ViewModelBinding()
        let reader = ViewModelBinding()
        defer {
            reader.dispose()
            owner.dispose()
        }
        let otherSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "other", tag: "other"
        ) { CachedLookupDisposalViewModel() }
        let disposingSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "disposing", tag: "shared"
        ) { CachedLookupDisposalViewModel() }
        let other = owner.read(otherSpec)
        let newest = owner.read(disposingSpec)
        var callbacks = 0
        newest.unbindAction = { _ in
            callbacks += 1
            do {
                let _: CachedLookupDisposalViewModel = try reader.readCached(tag: "shared")
                XCTFail("A tag with no live matches must not resolve through a binding")
            } catch {
                XCTAssertTrue(error is ViewModelError)
            }
            do {
                let _: CachedLookupDisposalViewModel = try ViewModel.readCached(tag: "shared")
                XCTFail("A tag with no live matches must not resolve through static lookup")
            } catch {
                XCTAssertTrue(error is ViewModelError)
            }
            let maybeBound: CachedLookupDisposalViewModel? = reader.maybeReadCached(tag: "shared")
            let maybeUnbound: CachedLookupDisposalViewModel? = ViewModel.maybeReadCached(tag: "shared")
            XCTAssertNil(maybeBound)
            XCTAssertNil(maybeUnbound)
            do {
                let readMatches: [CachedLookupDisposalViewModel] = try reader.readCachesByTagThrowing(
                    "shared"
                )
                let watchMatches: [CachedLookupDisposalViewModel] = try reader.watchCachesByTagThrowing(
                    "shared"
                )
                XCTAssertTrue(readMatches.isEmpty)
                XCTAssertTrue(watchMatches.isEmpty)
            } catch {
                XCTFail("An unavailable tag must return an empty batch, not throw: \(error)")
            }
        }

        owner.recycle(newest)

        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(newest.isDisposed)
        XCTAssertFalse(other.isDisposed)
    }

    /// Exercise the lookup before disposal listeners evict the newest handle.
    /// Two older matches verify newest-first ordering; another tag must not leak
    /// into tagged results. All fixtures remain owned throughout the callback.
    private func withDisposingNewest(
        _ assertion: @escaping @MainActor (
            HostedViewModelBinding,
            CachedLookupDisposalViewModel,
            CachedLookupDisposalViewModel,
            CachedLookupDisposalViewModel
        ) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let owner = ViewModelBinding()
        let reader = HostedViewModelBinding()
        defer {
            reader.dispose()
            owner.dispose()
        }
        let oldestSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "oldest", tag: "shared"
        ) { CachedLookupDisposalViewModel() }
        let otherSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "other", tag: "other"
        ) { CachedLookupDisposalViewModel() }
        let liveSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "newest-live", tag: "shared"
        ) { CachedLookupDisposalViewModel() }
        let disposingSpec = ViewModelSpec<CachedLookupDisposalViewModel>(
            key: "disposing", tag: "shared"
        ) { CachedLookupDisposalViewModel() }
        let oldestLive = owner.read(oldestSpec)
        _ = owner.read(otherSpec)
        let newestLive = owner.read(liveSpec)
        let newest = owner.read(disposingSpec)
        var callbacks = 0
        newest.unbindAction = { disposing in
            callbacks += 1
            do {
                try assertion(reader, newestLive, oldestLive, disposing)
            } catch {
                XCTFail("Live cached fallback should succeed during disposal: \(error)", file: file, line: line)
            }
        }

        owner.recycle(newest)

        XCTAssertEqual(callbacks, 1, file: file, line: line)
        XCTAssertTrue(newest.isDisposed, file: file, line: line)
        XCTAssertEqual(newest.onDisposeCalls, 1, file: file, line: line)
        XCTAssertFalse(newestLive.isDisposed, file: file, line: line)
        XCTAssertFalse(oldestLive.isDisposed, file: file, line: line)
    }
}
