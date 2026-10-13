import XCTest
@_spi(Internal) @testable import AppleViewModel

@MainActor
private final class OwnershipEvents {
    var values: [String] = []
}

private enum OwnershipFailure: Error { case construction }

@MainActor
private final class OwnershipNode: ViewModel {
    let name: String
    let events: OwnershipEvents
    let created: ((OwnershipNode) throws -> Void)?
    let bound: ((OwnershipNode, String) throws -> Void)?
    let unbound: ((OwnershipNode, String) throws -> Void)?

    init(
        name: String,
        events: OwnershipEvents,
        construct: ((OwnershipNode) throws -> Void)?,
        created: ((OwnershipNode) throws -> Void)?,
        bound: ((OwnershipNode, String) throws -> Void)?,
        unbound: ((OwnershipNode, String) throws -> Void)?
    ) throws {
        self.name = name
        self.events = events
        self.created = created
        self.bound = bound
        self.unbound = unbound
        super.init()
        addDispose { events.values.append("cleanup:\(name)") }
        try construct?(self)
    }

    override func onCreate(_ arg: InstanceArg) {
        super.onCreate(arg)
        events.values.append("create:\(name)")
        do { try created?(self) } catch { XCTFail("Unexpected onCreate error: \(error)") }
    }

    override func onBind(_ arg: InstanceArg, bindingId: String) {
        super.onBind(arg, bindingId: bindingId)
        events.values.append("bind:\(name):\(bindingId)")
        do { try bound?(self, bindingId) } catch { XCTFail("Unexpected onBind error: \(error)") }
    }

    override func onUnbind(_ arg: InstanceArg, bindingId: String) {
        super.onUnbind(arg, bindingId: bindingId)
        events.values.append("unbind:\(name):\(bindingId)")
        do { try unbound?(self, bindingId) } catch { XCTFail("Unexpected onUnbind error: \(error)") }
    }

    override func onDispose(_ arg: InstanceArg) {
        events.values.append("dispose:\(name)")
        super.onDispose(arg)
    }
}

@MainActor
private final class OwnershipBinding: ViewModelBinding {
    var updates = 0
    var refreshed: (() throws -> Void)?

    override func onUpdate() {
        updates += 1
        do { try refreshed?() } catch { XCTFail("Unexpected refresh error: \(error)") }
    }
}

@MainActor
final class OwnershipCommitTests: XCTestCase {
    private let events = OwnershipEvents()

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            ViewModel.reset()
            ViewModel.initialize(config: ViewModelConfig(onError: { error, _ in
                XCTFail("Ownership callbacks must not hide errors: \(error)")
            }))
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated { ViewModel.reset() }
        super.tearDown()
    }

    private func spec(
        _ name: String,
        tag: String? = nil,
        retained: Bool = false,
        build: (() -> Void)? = nil,
        construct: ((OwnershipNode) throws -> Void)? = nil,
        created: ((OwnershipNode) throws -> Void)? = nil,
        bound: ((OwnershipNode, String) throws -> Void)? = nil,
        unbound: ((OwnershipNode, String) throws -> Void)? = nil
    ) -> ViewModelSpec<OwnershipNode> {
        let events = events
        return ViewModelSpec(key: name, tag: tag, aliveForever: retained, throwingBuilder: {
            build?()
            return try OwnershipNode(
                name: name, events: events, construct: construct,
                created: created, bound: bound, unbound: unbound
            )
        })
    }

    private func handle(_ key: String) throws -> InstanceHandle<OwnershipNode> {
        try InstanceManager.shared.getHandle(
            OwnershipNode.self, factory: InstanceFactory(arg: InstanceArg(key: key))
        )
    }

    func test_lifecycleSeesCommittedOwnersAndReadPreservesWatch() throws {
        let owner = OwnershipBinding()
        defer { owner.dispose() }
        var phases: [String] = []
        var handleOwners: [Set<String>] = []
        var refOwners: [[String]] = []
        func snapshot(_ node: OwnershipNode, _ phase: String) throws {
            phases.append(phase)
            handleOwners.append(Set(try handle("node").bindingIds))
            refOwners.append(node.refHandler.owners.map(\.id))
        }
        let factory = spec(
            "node", bound: { node, _ in try snapshot(node, "bind") },
            unbound: { node, _ in try snapshot(node, "unbind") }
        )
        let node = try owner.readThrowing(factory)
        XCTAssertTrue(try owner.watchThrowing(factory) === node)
        XCTAssertTrue(try owner.watchThrowing(factory) === node)
        try owner.readThrowing(factory).notifyListeners()
        XCTAssertEqual(owner.updates, 1)
        owner.dispose()

        XCTAssertEqual(phases, ["bind", "unbind"])
        XCTAssertEqual(handleOwners, [Set([owner.id]), Set<String>()])
        XCTAssertEqual(refOwners, [[owner.id], []])
        XCTAssertEqual(events.values, [
            "create:node", "bind:node:\(owner.id)", "unbind:node:\(owner.id)",
            "dispose:node", "cleanup:node"
        ])
    }

    func test_onBindCanReadAndWatchSameGeneration() throws {
        let owner = OwnershipBinding()
        defer { owner.dispose() }
        var factory: ViewModelSpec<OwnershipNode>!
        var sameGeneration = false
        factory = spec("node", bound: { node, _ in
            sameGeneration = try owner.watchThrowing(factory) === node
            XCTAssertTrue(try owner.readThrowing(factory) === node)
        })
        let node = try owner.readThrowing(factory)
        node.notifyListeners()
        XCTAssertTrue(sameGeneration)
        XCTAssertEqual(owner.updates, 1)
        XCTAssertEqual(events.values, ["create:node", "bind:node:\(owner.id)"])
        XCTAssertEqual(node.refHandler.owners.map(\.id), [owner.id])
    }

    func test_disposalDuringConstructionOrBindingRollsBackNewGeneration() {
        for phase in ["builder", "create", "bind"] {
            for retained in [false, true] {
                let owner = OwnershipBinding()
                defer { owner.dispose() }
                events.values.removeAll()
                let factory = spec(
                    "node", retained: retained,
                    build: { if phase == "builder" { owner.dispose() } },
                    created: { _ in if phase == "create" { owner.dispose() } },
                    bound: { _, _ in if phase == "bind" { owner.dispose() } }
                )
                XCTAssertThrowsError(try owner.readThrowing(factory))
                XCTAssertTrue(owner.isDisposed)
                XCTAssertEqual(events.values.filter { $0 == "dispose:node" }.count, 1)
                XCTAssertEqual(events.values.filter { $0 == "cleanup:node" }.count, 1)
                XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
                XCTAssertNil(ViewModel.maybeReadCached(key: "node") as OwnershipNode?)
            }
        }
    }

    func test_cacheHitRollbackPreservesKeeperAndItsWatch() throws {
        let keeper = OwnershipBinding()
        let joining = OwnershipBinding()
        defer { keeper.dispose(); joining.dispose() }
        let factory = spec("node", bound: { _, id in
            if id == joining.id { joining.dispose() }
        })
        let node = try keeper.watchThrowing(factory)
        XCTAssertThrowsError(try joining.watchThrowing(factory))
        XCTAssertEqual(node.refHandler.owners.map(\.id), [keeper.id])
        XCTAssertEqual(Set(try handle("node").bindingIds), Set([keeper.id]))
        node.notifyListeners()
        XCTAssertEqual(keeper.updates, 1)
        XCTAssertEqual(joining.updates, 0)
        XCTAssertFalse(node.isDisposed)
    }

    func test_failedInitialAttachmentPreservesReentrantOwner() throws {
        for retained in [false, true] {
            let first = OwnershipBinding()
            let survivor = OwnershipBinding()
            defer { first.dispose(); survivor.dispose() }
            let key = "survivor-\(retained)"
            var factory: ViewModelSpec<OwnershipNode>!
            factory = spec(key, retained: retained, bound: { node, id in
                if id == first.id {
                    XCTAssertTrue(try survivor.watchThrowing(factory) === node)
                    first.dispose()
                }
            })
            XCTAssertThrowsError(try first.readThrowing(factory))
            let node = try survivor.readThrowing(factory)
            XCTAssertFalse(node.isDisposed)
            XCTAssertEqual(node.refHandler.owners.map(\.id), [survivor.id])
            XCTAssertEqual(Set(try handle(key).bindingIds), Set([survivor.id]))
            node.notifyListeners()
            XCTAssertEqual(survivor.updates, 1)
            XCTAssertEqual(events.values.filter { $0 == "create:\(key)" }.count, 1)
            survivor.dispose()
            if retained { XCTAssertTrue(InstanceManager.shared.recycle(node)) }
        }
    }

    func test_onUnbindReacquiresWithoutLosingNewRegistration() throws {
        let keeper = OwnershipBinding()
        let owner = OwnershipBinding()
        defer { keeper.dispose(); owner.dispose() }
        var rebind = true
        var factory: ViewModelSpec<OwnershipNode>!
        factory = spec("node", unbound: { _, id in
            if id == owner.id, rebind {
                rebind = false
                _ = try owner.watchThrowing(factory)
            }
        })
        _ = try keeper.readThrowing(factory)
        let node = try owner.watchThrowing(factory)
        events.values.removeAll()
        owner.unbind(node)
        XCTAssertEqual(events.values, ["unbind:node:\(owner.id)", "bind:node:\(owner.id)"])
        XCTAssertEqual(node.refHandler.owners.map(\.id), [keeper.id, owner.id])
        node.notifyListeners()
        XCTAssertEqual(owner.updates, 1)
        owner.dispose()
        XCTAssertEqual(node.refHandler.owners.map(\.id), [keeper.id])
    }

    func test_childOnBindCanRemoveJoiningRootDuringPropagation() throws {
        let keeper = OwnershipBinding()
        let joining = OwnershipBinding()
        defer { keeper.dispose(); joining.dispose() }
        let parentSpec = spec("parent")
        let childSpec = spec("child", bound: { _, id in
            if id == joining.id { joining.dispose() }
        })
        let siblingSpec = spec("sibling")
        let parent = try keeper.readThrowing(parentSpec)
        _ = try parent.viewModelBinding.readThrowing(childSpec)
        _ = try parent.viewModelBinding.readThrowing(siblingSpec)
        XCTAssertThrowsError(try joining.readThrowing(parentSpec))
        XCTAssertEqual(parent.refHandler.externalOwners.map(\.id), [keeper.id])
        for factory in [childSpec, siblingSpec] {
            let child = try parent.viewModelBinding.readThrowing(factory)
            XCTAssertEqual(child.refHandler.externalOwners.map(\.id), [keeper.id])
            XCTAssertFalse(try handle(child.name).contains(bindingId: joining.id))
        }
        keeper.dispose()
        XCTAssertEqual(events.values.filter { $0.hasPrefix("dispose:") }.count, 3)
    }

    func test_ownerListenersDoNotDeliverStaleSnapshotAfterReentry() throws {
        let keeper = OwnershipBinding()
        let joining = OwnershipBinding()
        defer { keeper.dispose(); joining.dispose() }
        let factory = spec("node")
        let node = try keeper.readThrowing(factory)
        var snapshots: [[String]] = []
        let cancelFirst = node.refHandler.addOwnerChangeListener { owners, _, _ in
            if owners.contains(joining.id) { joining.dispose() }
        }
        let cancelSecond = node.refHandler.addOwnerChangeListener { owners, _, _ in
            snapshots.append(owners)
        }
        defer { cancelFirst(); cancelSecond() }
        XCTAssertThrowsError(try joining.readThrowing(factory))
        XCTAssertEqual(snapshots, [[keeper.id]])
        XCTAssertEqual(node.refHandler.owners.map(\.id), [keeper.id])
        XCTAssertTrue(node.refHandler.primaryOwner === keeper)
    }

    func test_cycleRejectionHasNoOwnershipOrLifecycleSideEffects() throws {
        let a = OwnershipBinding()
        let b = OwnershipBinding()
        defer { a.dispose(); b.dispose() }
        let aSpec = spec("a")
        let bSpec = spec("b")
        let first = try a.watchThrowing(aSpec)
        let second = try first.viewModelBinding.watchThrowing(bSpec)
        _ = try b.watchThrowing(bSpec)
        let owners = Set(try handle("a").bindingIds)
        var changes = 0
        let cancel = first.refHandler.addOwnerChangeListener { _, _, _ in changes += 1 }
        defer { cancel() }
        events.values.removeAll()

        XCTAssertThrowsError(try second.viewModelBinding.readThrowing(aSpec))
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(Set(try handle("a").bindingIds), owners)
        second.notifyListeners()
        XCTAssertEqual(a.updates, 1)
        XCTAssertEqual(b.updates, 1)
    }

    func test_onBindReverseCycleCheckSeesCommittedDependencyEdge() throws {
        let owner = OwnershipBinding()
        defer { owner.dispose() }
        let aSpec = spec("a")
        var rejected = false
        let bSpec = spec("b", bound: { node, id in
            if id != owner.id {
                do {
                    _ = try node.viewModelBinding.readThrowing(aSpec)
                } catch {
                    rejected = true
                    XCTAssertTrue(String(describing: error).contains("Circular ViewModel dependency"))
                }
            }
        })
        let parent = try owner.readThrowing(aSpec)
        let child = try parent.viewModelBinding.readThrowing(bSpec)
        XCTAssertTrue(rejected)
        XCTAssertEqual(parent.refHandler.owners.map(\.id), [owner.id])
        XCTAssertEqual(child.refHandler.externalOwners.map(\.id), [owner.id])
    }

    func test_rejectedTagBatchPreservesExistingEdgesAndSubscriptions() throws {
        for watch in [false, true] {
            let owner = OwnershipBinding()
            let keeper = OwnershipBinding()
            defer { owner.dispose(); keeper.dispose() }
            let suffix = "\(watch)"
            let aSpec = spec("a-\(suffix)", tag: suffix)
            let bSpec = spec("b-\(suffix)", tag: suffix)
            let cSpec = spec("c-\(suffix)", tag: suffix)
            let parent = try owner.watchThrowing(aSpec)
            let b = try keeper.readThrowing(bSpec)
            let c = try keeper.readThrowing(cSpec)
            _ = try parent.viewModelBinding.watchThrowing(cSpec)
            let bOwners = Set(try handle(b.name).bindingIds)
            let cOwners = Set(try handle(c.name).bindingIds)
            events.values.removeAll()
            // Newest-first order puts the invalid self edge last.
            if watch {
                XCTAssertThrowsError(
                    try parent.viewModelBinding.watchCachesByTagThrowing(suffix) as [OwnershipNode]
                )
            } else {
                XCTAssertThrowsError(
                    try parent.viewModelBinding.readCachesByTagThrowing(suffix) as [OwnershipNode]
                )
            }
            XCTAssertTrue(events.values.isEmpty)
            XCTAssertEqual(Set(try handle(b.name).bindingIds), bOwners)
            XCTAssertEqual(Set(try handle(c.name).bindingIds), cOwners)
            c.notifyListeners()
            XCTAssertEqual(owner.updates, 1)
            b.notifyListeners()
            XCTAssertEqual(owner.updates, 1)
        }
    }

    func test_failedConstructionReleasesTentativeEdgesAndPreservesSharedWatch() throws {
        let childOwner = OwnershipBinding()
        let parentOwner = OwnershipBinding()
        defer { childOwner.dispose(); parentOwner.dispose() }
        let childSpec = spec("child")
        let parentSpec = spec("failed", construct: { node in
            _ = try node.viewModelBinding.watchThrowing(childSpec)
            throw OwnershipFailure.construction
        })
        let child = try childOwner.watchThrowing(childSpec)
        XCTAssertThrowsError(try parentOwner.readThrowing(parentSpec)) { error in
            XCTAssertTrue(error is OwnershipFailure)
        }
        XCTAssertEqual(child.refHandler.owners.map(\.id), [childOwner.id])
        XCTAssertEqual(Set(try handle("child").bindingIds), Set([childOwner.id]))
        XCTAssertEqual(events.values.filter { $0 == "cleanup:failed" }.count, 1)
        XCTAssertNil(ViewModel.maybeReadCached(key: "failed") as OwnershipNode?)
        child.notifyListeners()
        XCTAssertEqual(childOwner.updates, 1)
        XCTAssertEqual(parentOwner.updates, 0)
    }

    func test_interruptedBatchRollsBackOnlyNewRegistrations() throws {
        for watch in [false, true] {
            let keeper = OwnershipBinding()
            let joining = OwnershipBinding()
            defer { keeper.dispose(); joining.dispose() }
            let tag = "batch-\(watch)"
            let bSpec = spec("b-\(watch)", tag: tag)
            let aSpec = spec("a-\(watch)", tag: tag, bound: { _, id in
                if id == joining.id { keeper.recycle(try keeper.readThrowing(bSpec)) }
            })
            let cSpec = spec("c-\(watch)", tag: tag)
            let dSpec = spec("existing-\(watch)", tag: tag)
            _ = try keeper.readThrowing(bSpec)
            let a = try keeper.watchThrowing(aSpec)
            let c = try keeper.readThrowing(cSpec)
            let existing = try joining.watchThrowing(dSpec)
            // Visit an existing registration, acquire c and a, then fail at b.
            if watch {
                XCTAssertThrowsError(try joining.watchCachesByTagThrowing(tag) as [OwnershipNode])
            } else {
                XCTAssertThrowsError(try joining.readCachesByTagThrowing(tag) as [OwnershipNode])
            }
            XCTAssertEqual(a.refHandler.owners.map(\.id), [keeper.id])
            XCTAssertEqual(c.refHandler.owners.map(\.id), [keeper.id])
            XCTAssertEqual(existing.refHandler.owners.map(\.id), [joining.id])
            a.notifyListeners()
            c.notifyListeners()
            existing.notifyListeners()
            XCTAssertEqual(keeper.updates, 2, "One recycle refresh and one watched notification")
            XCTAssertEqual(joining.updates, 1, "Only the pre-existing watch survives")
        }
    }

    func test_failedBatchPreservesReentrantReplacementRegistration() throws {
        let keeper = OwnershipBinding()
        let joining = OwnershipBinding()
        defer { keeper.dispose(); joining.dispose() }
        let bSpec = spec("b", tag: "batch")
        let cSpec = spec("c", tag: "batch")
        let aSpec = spec("a", tag: "batch", bound: { _, id in
            if id == joining.id {
                joining.unbind(try keeper.readThrowing(cSpec))
                _ = try joining.watchThrowing(cSpec)
                keeper.recycle(try keeper.readThrowing(bSpec))
            }
        })
        _ = try keeper.readThrowing(bSpec)
        let a = try keeper.readThrowing(aSpec)
        let c = try keeper.readThrowing(cSpec)
        // c is acquired first, then a replaces c's registration and invalidates
        // the remaining b. Rollback must release only the original c attempt.
        XCTAssertThrowsError(try joining.readCachesByTagThrowing("batch") as [OwnershipNode])
        XCTAssertEqual(a.refHandler.owners.map(\.id), [keeper.id])
        XCTAssertEqual(c.refHandler.owners.map(\.id), [keeper.id, joining.id])
        XCTAssertTrue(try handle("c").containsDirectBinding(joining.id))
        c.notifyListeners()
        XCTAssertEqual(joining.updates, 1)
        joining.dispose()
        XCTAssertEqual(c.refHandler.owners.map(\.id), [keeper.id])
        XCTAssertFalse(c.isDisposed)
    }

    func test_recycleDuringOnUnbindIsIdempotentAndRefreshResolvesReplacement() throws {
        let owner = OwnershipBinding()
        defer { owner.refreshed = nil; owner.dispose() }
        let factory = spec("node", unbound: { node, _ in owner.recycle(node) })
        let previous = try owner.readThrowing(factory)
        owner.refreshed = { _ = try owner.readThrowing(factory) }
        owner.recycle(previous)
        let current = try owner.readThrowing(factory)
        XCTAssertFalse(previous === current)
        XCTAssertFalse(current.isDisposed)
        XCTAssertEqual(current.refHandler.owners.map(\.id), [owner.id])
        XCTAssertEqual(events.values.filter { $0 == "dispose:node" }.count, 1)
        XCTAssertEqual(events.values.filter { $0.hasPrefix("unbind:") }.count, 1)
    }

    func test_reentrantChildAttachmentSurvivesOldEdgeCleanup() throws {
        for rebindFromRoot in [false, true] {
            let childOwner = OwnershipBinding()
            let parentOwner = OwnershipBinding()
            defer { childOwner.dispose(); parentOwner.dispose() }
            let suffix = "\(rebindFromRoot)"
            let parentSpec = spec("parent-\(suffix)")
            let parent = try parentOwner.watchThrowing(parentSpec)
            let dependency = parent.viewModelBinding
            var reattach = true
            var childSpec: ViewModelSpec<OwnershipNode>!
            childSpec = spec("child-\(suffix)", unbound: { _, id in
                let trigger = rebindFromRoot ? parentOwner.id : dependency.id
                if id == trigger, reattach {
                    reattach = false
                    _ = try dependency.watchThrowing(childSpec)
                }
            })
            let child = try childOwner.readThrowing(childSpec)
            _ = try dependency.watchThrowing(childSpec)
            dependency.unbind(child)
            XCTAssertEqual(Set(child.refHandler.externalOwners.map(\.id)), Set([childOwner.id, parentOwner.id]))
            XCTAssertTrue(try handle(child.name).containsDirectBinding(dependency.id))
            XCTAssertEqual(parentOwner.updates, 0, "Explicit unbind does not refresh")
            child.notifyListeners()
            XCTAssertEqual(parentOwner.updates, 1)
            parentOwner.dispose()
            XCTAssertEqual(child.refHandler.owners.map(\.id), [childOwner.id])
        }
    }

    func test_recycleEvictsParentBeforePropagatedUnbindAndCoalescesRefresh() throws {
        let owner = OwnershipBinding()
        defer { owner.dispose() }
        let parentSpec = spec("parent")
        var resolveInUnbind = true
        let childSpec = spec("child", unbound: { _, id in
            if id == owner.id, resolveInUnbind {
                resolveInUnbind = false
                try owner.watchThrowing(parentSpec).notifyListeners()
            }
        })
        let previous = try owner.watchThrowing(parentSpec)
        _ = try previous.viewModelBinding.readThrowing(childSpec)
        owner.recycle(previous)
        let current = try owner.readThrowing(parentSpec)
        XCTAssertFalse(current === previous)
        XCTAssertFalse(current.isDisposed)
        XCTAssertEqual(owner.updates, 1)
        XCTAssertEqual(events.values.filter { $0 == "dispose:parent" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "dispose:child" }.count, 1)
    }

    func test_bindingDisposalToleratesRecyclingAnotherTrackedHandle() throws {
        let owner = OwnershipBinding()
        defer { owner.dispose() }
        var recycledPeer = false
        func recyclePeer(_ key: String) {
            if let peer: OwnershipNode = ViewModel.maybeReadCached(key: key) {
                recycledPeer = InstanceManager.shared.recycle(peer) || recycledPeer
            }
        }
        let aSpec = spec("a", unbound: { _, _ in recyclePeer("b") })
        let bSpec = spec("b", unbound: { _, _ in recyclePeer("a") })
        _ = try owner.readThrowing(aSpec)
        _ = try owner.readThrowing(bSpec)
        owner.dispose()
        XCTAssertTrue(recycledPeer)
        XCTAssertEqual(events.values.filter { $0 == "dispose:a" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "dispose:b" }.count, 1)
        XCTAssertEqual(InstanceManager.shared.debugStoreCount, 0)
    }
}
