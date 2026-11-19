import XCTest
@_spi(Internal) @testable import AppleViewModel

@MainActor
private final class ChainLog {
    var disposed: [String] = []
}

/// A shared ViewModel read by every cell of a long list, whose dependencies
/// mirror every cell as an owner. Owner propagation must stay linear per owner
/// change, otherwise building or unmounting such a list hangs.
@MainActor
private final class ChainNode: ViewModel {
    init(name: String, next: ViewModelSpec<ChainNode>?, log: ChainLog) {
        super.init()
        addDispose { log.disposed.append(name) }
        if let next { _ = viewModelBinding.read(next) }
    }
}

@MainActor
final class ManyOwnersTests: XCTestCase {
    private let log = ChainLog()

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { ViewModel.reset() }
    }

    override func tearDown() {
        MainActor.assumeIsolated { ViewModel.reset() }
        super.tearDown()
    }

    private func chain(_ depth: Int) -> ViewModelSpec<ChainNode> {
        let log = log
        var next: ViewModelSpec<ChainNode>?
        for level in stride(from: depth - 1, through: 0, by: -1) {
            let below = next
            next = ViewModelSpec(key: "level\(level)") {
                ChainNode(name: "level\(level)", next: below, log: log)
            }
        }
        return next!
    }

    private func handle(_ key: String) throws -> InstanceHandle<ChainNode> {
        try InstanceManager.shared.getHandle(
            ChainNode.self, factory: InstanceFactory(arg: InstanceArg(key: key))
        )
    }

    func test_thousandsOfOwnersPropagateToDependenciesInLinearTime() throws {
        let owners = 1500
        let depth = 4
        let spec = chain(depth)
        let cells = (0..<owners).map { _ in ViewModelBinding() }
        defer { cells.forEach { $0.dispose() } }

        let clock = ContinuousClock()
        let bound = clock.measure {
            for cell in cells { _ = cell.read(spec) }
        }

        for level in 0..<depth {
            // Deeper levels are also owned by the parent's dependency binding.
            let handle = try handle("level\(level)")
            XCTAssertEqual(handle.bindingIds.count, owners + (level == 0 ? 0 : 1), "level\(level)")
            XCTAssertEqual(handle.value?.refHandler.externalOwners.count, owners)
        }

        // Unmount in the order a list unmounts its cells.
        let released = clock.measure {
            for cell in cells { cell.dispose() }
        }

        XCTAssertEqual(log.disposed, ["level0", "level1", "level2", "level3"])
        // Quadratic owner sync took tens of seconds here; linear sync takes
        // milliseconds. Debug builds still need a loose bound.
        XCTAssertLessThan(bound + released, .seconds(5), "bind \(bound), release \(released)")
    }

    func test_releasingOwnersFromTheMiddleKeepsTheRemainingPropagation() throws {
        let owners = 200
        let spec = chain(3)
        let cells = (0..<owners).map { _ in ViewModelBinding() }
        defer { cells.forEach { $0.dispose() } }
        for cell in cells { _ = cell.read(spec) }

        for index in stride(from: 0, to: owners, by: 2) { cells[index].dispose() }
        let kept = stride(from: 1, to: owners, by: 2).map { cells[$0].id }
        let cellIds = Set(cells.map(\.id))
        for level in 0..<3 {
            let handle = try handle("level\(level)")
            XCTAssertEqual(Set(handle.bindingIds).intersection(cellIds), Set(kept), "level\(level)")
            XCTAssertEqual(handle.value?.refHandler.externalOwners.map(\.id), kept)
        }
        XCTAssertTrue(log.disposed.isEmpty)

        for index in stride(from: 1, to: owners, by: 2) { cells[index].dispose() }
        XCTAssertEqual(log.disposed, ["level0", "level1", "level2"])
    }
}
