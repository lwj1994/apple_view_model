import XCTest
@testable import AppleViewModel

/// Regression coverage for the binding-resolution mechanism used during
/// `ViewModel.init()` and `ViewModel.onCreate(_:)`.
///
/// Mechanism (post-`@TaskLocal` removal):
/// - `ViewModelBinding.createViewModel` wraps `factory.build()` in
///   `ViewModelBinding.withBuilding(self) { … }`, pushing `self` onto a
///   `@MainActor`-local stack so `viewModelBinding` reads during the VM's
///   `init()` body resolve to the builder.
/// - The same closure calls `vm.refHandler.addRef(self)` immediately after
///   `factory.build()` returns and before `InstanceHandle.init` invokes
///   `onCreate(_:)`. From that point on, `viewModelBinding` reads from
///   `dependencyBindings.first` and is no longer sensitive to execution
///   context — `Task.detached`, Combine sinks, UIKit callbacks all see it.
@MainActor
final class OnCreateBindingResolutionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    /// The headline regression: resolving a dependency from inside `onCreate`
    /// must not trap and must return the same instance the parent binding
    /// would resolve directly.
    func test_onCreate_can_read_dependency_via_viewModelBinding() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM>(key: "dep") { DepVM() }

        final class HostVM: ViewModel {
            var dep: DepVM?
            static var spec: ViewModelSpec<DepVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                dep = viewModelBinding.read(Self.spec)
            }
        }
        HostVM.spec = depSpec

        let hostSpec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        let host = b.watch(hostSpec)

        XCTAssertNotNil(host.dep)
        let direct: DepVM = try! b.readCached(key: "dep")
        XCTAssertTrue(host.dep === direct)
    }

    /// Same shape with `watch`. The listener wired up via `viewModelBinding.watch`
    /// must fan changes back to the parent binding, so notifying `dep` triggers
    /// `onUpdate` on the parent.
    func test_onCreate_can_watch_dependency_and_receives_updates() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM>(key: "watch-dep") { DepVM() }

        final class HostVM: ViewModel {
            var dep: DepVM?
            static var spec: ViewModelSpec<DepVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                dep = viewModelBinding.watch(Self.spec)
            }
        }
        HostVM.spec = depSpec

        final class CountingBinding: ViewModelBinding {
            var updates: Int = 0
            override func onUpdate() { updates += 1 }
        }

        let hostSpec = ViewModelSpec<HostVM> { HostVM() }
        let b = CountingBinding()
        let host = b.watch(hostSpec)
        let dep = host.dep!

        let updatesAfterCreate = b.updates
        dep.notifyListeners()
        XCTAssertEqual(b.updates, updatesAfterCreate + 1)
    }

    /// Inside `onCreate`, `viewModelBinding` must resolve to the parent binding.
    /// With the post-TaskLocal mechanism, this works because
    /// `refHandler.addRef(binding)` fires inside the builder closure
    /// *before* `InstanceHandle.init` invokes `onCreate(_:)`.
    func test_onCreate_resolves_binding_inside_callback() {
        final class HostVM: ViewModel {
            var resolvedBinding: ViewModelBinding?

            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                resolvedBinding = viewModelBinding
            }
        }

        let spec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        let host = b.watch(spec)

        XCTAssertTrue(host.resolvedBinding === b,
                      "viewModelBinding must resolve to the parent binding inside onCreate")
    }

    /// Headline win of replacing `@TaskLocal` with addRef-first + MainActor
    /// stack: a `Task.detached` started during `onCreate` (and therefore
    /// running on a *different* Task with no TaskLocal inheritance) still
    /// resolves `viewModelBinding` correctly via `dependencyBindings`.
    func test_task_detached_inside_onCreate_can_resolve_binding() {
        final class HostVM: ViewModel {
            static var pendingExpectation: XCTestExpectation?
            static var resolvedFromDetached: ViewModelBinding?

            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                let expectation = Self.pendingExpectation
                Task.detached { @MainActor [weak self] in
                    guard let self else { return }
                    Self.resolvedFromDetached = self.viewModelBinding
                    expectation?.fulfill()
                }
            }
        }

        let expectation = expectation(description: "detached resolves binding")
        HostVM.pendingExpectation = expectation
        HostVM.resolvedFromDetached = nil

        let spec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        _ = b.watch(spec)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(HostVM.resolvedFromDetached === b,
                      "Task.detached spawned in onCreate must still see the parent binding "
                      + "through refHandler.dependencyBindings — the buildingStack is empty by then")

        HostVM.pendingExpectation = nil
        HostVM.resolvedFromDetached = nil
    }

    /// `init()` and `onCreate(_:)` should both resolve to the same parent
    /// binding and therefore the same shared dependency instance.
    func test_init_and_onCreate_resolve_same_dependency_instance() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM>(key: "shared") { DepVM() }

        final class HostVM: ViewModel {
            var depFromInit: DepVM!
            var depFromOnCreate: DepVM?
            static var spec: ViewModelSpec<DepVM>!
            override init() {
                super.init()
                depFromInit = viewModelBinding.read(Self.spec)
            }
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                depFromOnCreate = viewModelBinding.read(Self.spec)
            }
        }
        HostVM.spec = depSpec

        let hostSpec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        let host = b.watch(hostSpec)

        XCTAssertNotNil(host.depFromInit)
        XCTAssertNotNil(host.depFromOnCreate)
        XCTAssertTrue(host.depFromInit === host.depFromOnCreate)
    }

    /// A dependency obtained during `onCreate` must be reference-counted on
    /// the parent binding, so disposing the parent cascades down to dispose
    /// both the host and the dep.
    func test_dependency_acquired_in_onCreate_disposes_with_parent() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM> { DepVM() }

        final class HostVM: ViewModel {
            var dep: DepVM?
            static var spec: ViewModelSpec<DepVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                dep = viewModelBinding.read(Self.spec)
            }
        }
        HostVM.spec = depSpec

        let hostSpec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        let host = b.watch(hostSpec)
        let dep = host.dep!

        XCTAssertFalse(host.isDisposed)
        XCTAssertFalse(dep.isDisposed)

        b.dispose()
        XCTAssertTrue(host.isDisposed)
        XCTAssertTrue(dep.isDisposed)
    }

    /// Nested resolution: each layer's `onCreate` fetches the next dep through
    /// `viewModelBinding`. Because `withValue(self)` is reentrant on the parent
    /// binding, every layer must resolve to that same parent and the whole
    /// chain must dispose in lockstep.
    func test_nested_onCreate_dependency_chain_resolves_through_same_binding() {
        final class LeafVM: ViewModel {}
        let leafSpec = ViewModelSpec<LeafVM>(key: "leaf") { LeafVM() }

        final class MidVM: ViewModel {
            var leaf: LeafVM?
            static var leafSpec: ViewModelSpec<LeafVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                leaf = viewModelBinding.read(Self.leafSpec)
            }
        }
        MidVM.leafSpec = leafSpec
        let midSpec = ViewModelSpec<MidVM>(key: "mid") { MidVM() }

        final class RootVM: ViewModel {
            var mid: MidVM?
            static var midSpec: ViewModelSpec<MidVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                mid = viewModelBinding.read(Self.midSpec)
            }
        }
        RootVM.midSpec = midSpec
        let rootSpec = ViewModelSpec<RootVM> { RootVM() }

        let b = ViewModelBinding()
        let root = b.watch(rootSpec)
        let mid = root.mid!
        let leaf = mid.leaf!

        let directLeaf: LeafVM = try! b.readCached(key: "leaf")
        XCTAssertTrue(leaf === directLeaf)

        b.dispose()
        XCTAssertTrue(root.isDisposed)
        XCTAssertTrue(mid.isDisposed)
        XCTAssertTrue(leaf.isDisposed)
    }

    /// `onCreate` only fires the first time a key is built. A second binding
    /// that watches the cached instance must not re-trigger `onCreate`, and
    /// must not trap when the cached VM was originally created by another
    /// binding.
    func test_onCreate_fires_once_for_shared_cached_instance() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM>(key: "shared-dep") { DepVM() }

        final class HostVM: ViewModel {
            var onCreateRuns: Int = 0
            var dep: DepVM?
            static var spec: ViewModelSpec<DepVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                onCreateRuns += 1
                dep = viewModelBinding.read(Self.spec)
            }
        }
        HostVM.spec = depSpec
        let hostSpec = ViewModelSpec<HostVM>(key: "host") { HostVM() }

        let b1 = ViewModelBinding()
        let b2 = ViewModelBinding()
        let host1 = b1.watch(hostSpec)
        let host2 = b2.watch(hostSpec)

        XCTAssertTrue(host1 === host2)
        XCTAssertEqual(host1.onCreateRuns, 1,
                       "onCreate must run exactly once for a cached instance")
        XCTAssertNotNil(host1.dep)

        b1.dispose()
        XCTAssertFalse(host1.isDisposed,
                       "shared host stays alive while b2 still watches it")
        b2.dispose()
        XCTAssertTrue(host1.isDisposed)
    }

    /// A dep fetched in `onCreate` must be observable via `readCached` from a
    /// sibling binding too — the side effect of registering the dep on the
    /// parent binding propagates into the global instance registry.
    func test_dependency_registered_in_onCreate_visible_to_sibling_binding() {
        final class DepVM: ViewModel {}
        let depSpec = ViewModelSpec<DepVM>(key: "registry-dep") { DepVM() }

        final class HostVM: ViewModel {
            static var spec: ViewModelSpec<DepVM>!
            override func onCreate(_ arg: InstanceArg) {
                super.onCreate(arg)
                _ = viewModelBinding.read(Self.spec)
            }
        }
        HostVM.spec = depSpec

        let hostSpec = ViewModelSpec<HostVM> { HostVM() }
        let b = ViewModelBinding()
        _ = b.watch(hostSpec)

        let sibling = ViewModelBinding()
        let depFromSibling: DepVM = try! sibling.readCached(key: "registry-dep")
        let depFromOwner: DepVM = try! b.readCached(key: "registry-dep")
        XCTAssertTrue(depFromSibling === depFromOwner)

        sibling.dispose()
        b.dispose()
    }
}
