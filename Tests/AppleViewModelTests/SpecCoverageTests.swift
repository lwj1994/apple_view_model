import XCTest
@testable import AppleViewModel

private enum SpecCoverageError: Error { case rejected }

@MainActor
private final class DefaultCoverageFactory: ViewModelFactory {
    let spec = ViewModelSpec { CounterViewModel() }
    func build() -> CounterViewModel { spec.build() }
}

@MainActor
final class SpecCoverageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnv.reset()
    }

    func test_customFactoryUsesDefaultMetadataAndBuildImplementation() throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let factory = DefaultCoverageFactory()
        XCTAssertNil(factory.key())
        XCTAssertNil(factory.tag())
        XCTAssertFalse(factory.aliveForever())
        let vm = try binding.readThrowing(factory)
        XCTAssertTrue(binding.watch(factory) === vm)
        XCTAssertEqual(vm.onCreateCalls, 1)
    }

    func test_throwingSpecBuilderClosureCanBeWrappedByAnotherSpec() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let original = ViewModelSpec<CounterViewModel>(throwingBuilder: { CounterViewModel() })
        let wrapper = ViewModelSpec { original.builder() }
        let vm = binding.read(wrapper)
        XCTAssertEqual(vm.onCreateCalls, 1)
        XCTAssertFalse(vm.isDisposed)
    }

    func test_manualOverridesInsideTaskLocalScopeRestoreInAnyOrder() async {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let base = ViewModelSpec<CounterViewModel>(key: "base") { CounterViewModel() }
        let outer = ViewModelSpec<CounterViewModel>(key: "outer") { CounterViewModel() }
        let middle = ViewModelSpec<CounterViewModel>(key: "middle") { CounterViewModel() }
        let inner = ViewModelSpec<CounterViewModel>(key: "inner") { CounterViewModel() }
        await base.runWithOverride(outer) {
            let restoreMiddle = base.overrideWith(middle)
            let restoreInner = base.overrideWith(inner)
            XCTAssertEqual(binding.read(base).instanceArg.key, "inner")
            restoreMiddle()
            XCTAssertEqual(binding.read(base).instanceArg.key, "inner")
            restoreInner()
            restoreInner()
            XCTAssertEqual(binding.read(base).instanceArg.key, "outer")
        }
        XCTAssertEqual(binding.read(base).instanceArg.key, "base")
    }

    func test_arg1ThrowingBuilderMetadataProxiesAndTaskLocalOverrides() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let base = ViewModelSpecWithArg<CounterViewModel, Int>(
            throwingBuilder: { a0 in
                let vm = CounterViewModel()
                vm.count = a0
                return vm
            },
            key: { a0 in "base-\(a0)" },
            tag: { a0 in "tag-\(a0)" },
            aliveForever: { _ in true }
        )
        let resolved = base(1)
        let vm = try binding.readThrowing(resolved)
        XCTAssertEqual(vm.count, 1)
        XCTAssertEqual(vm.instanceArg.key, "base-1")
        XCTAssertEqual(vm.tag, "tag-1")
        XCTAssertTrue(vm.instanceArg.aliveForever)

        let wrapped = ViewModelSpec<CounterViewModel>(key: "wrapped") { base.builder(1) }
        XCTAssertEqual(binding.read(wrapped).count, vm.count)

        let proxy = ViewModelSpecWithArg<CounterViewModel, Int>(builder: { _ in
            let value = CounterViewModel()
            value.count = 100
            return value
        }, key: { _ in "proxy" })
        base.setProxy(proxy)
        XCTAssertEqual(binding.read(base(1)).count, 100)
        base.clearProxy()
        XCTAssertTrue(binding.read(base(1)) === vm)
        let value = await base.runWithOverride(proxy) {
            await Task.yield()
            return binding.read(base(1)).count
        }
        XCTAssertEqual(value, 100)
        XCTAssertTrue(binding.read(base(1)) === vm)

        let failing = ViewModelSpecWithArg<CounterViewModel, Int>(throwingBuilder: { _ in
            throw SpecCoverageError.rejected
        }, key: { _ in "rejected" })
        XCTAssertThrowsError(try binding.readThrowing(failing(1))) { error in
            XCTAssertTrue(error is SpecCoverageError)
        }
        binding.recycle(vm)
        XCTAssertTrue(vm.isDisposed)
    }

    func test_arg2ThrowingBuilderMetadataProxiesAndTaskLocalOverrides() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let base = ViewModelSpecWithArg2<CounterViewModel, Int, Int>(
            throwingBuilder: { a0, a1 in
                let vm = CounterViewModel()
                vm.count = a0 + a1
                return vm
            },
            key: { a0, a1 in "base-\(a0 + a1)" },
            tag: { a0, a1 in "tag-\(a0 + a1)" },
            aliveForever: { _, _ in true }
        )
        let resolved = base(1, 2)
        let vm = try binding.readThrowing(resolved)
        XCTAssertEqual(vm.count, 3)
        XCTAssertEqual(vm.instanceArg.key, "base-3")
        XCTAssertEqual(vm.tag, "tag-3")
        XCTAssertTrue(vm.instanceArg.aliveForever)

        let wrapped = ViewModelSpec<CounterViewModel>(key: "wrapped") { base.builder(1, 2) }
        XCTAssertEqual(binding.read(wrapped).count, vm.count)

        let proxy = ViewModelSpecWithArg2<CounterViewModel, Int, Int>(builder: { _, _ in
            let value = CounterViewModel()
            value.count = 100
            return value
        }, key: { _, _ in "proxy" })
        base.setProxy(proxy)
        XCTAssertEqual(binding.read(base(1, 2)).count, 100)
        base.clearProxy()
        XCTAssertTrue(binding.read(base(1, 2)) === vm)
        let value = await base.runWithOverride(proxy) {
            await Task.yield()
            return binding.read(base(1, 2)).count
        }
        XCTAssertEqual(value, 100)
        XCTAssertTrue(binding.read(base(1, 2)) === vm)

        let failing = ViewModelSpecWithArg2<CounterViewModel, Int, Int>(throwingBuilder: { _, _ in
            throw SpecCoverageError.rejected
        }, key: { _, _ in "rejected" })
        XCTAssertThrowsError(try binding.readThrowing(failing(1, 2))) { error in
            XCTAssertTrue(error is SpecCoverageError)
        }
        binding.recycle(vm)
        XCTAssertTrue(vm.isDisposed)
    }

    func test_arg3ThrowingBuilderMetadataProxiesAndTaskLocalOverrides() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let base = ViewModelSpecWithArg3<CounterViewModel, Int, Int, Int>(
            throwingBuilder: { a0, a1, a2 in
                let vm = CounterViewModel()
                vm.count = a0 + a1 + a2
                return vm
            },
            key: { a0, a1, a2 in "base-\(a0 + a1 + a2)" },
            tag: { a0, a1, a2 in "tag-\(a0 + a1 + a2)" },
            aliveForever: { _, _, _ in true }
        )
        let resolved = base(1, 2, 3)
        let vm = try binding.readThrowing(resolved)
        XCTAssertEqual(vm.count, 6)
        XCTAssertEqual(vm.instanceArg.key, "base-6")
        XCTAssertEqual(vm.tag, "tag-6")
        XCTAssertTrue(vm.instanceArg.aliveForever)

        let wrapped = ViewModelSpec<CounterViewModel>(key: "wrapped") { base.builder(1, 2, 3) }
        XCTAssertEqual(binding.read(wrapped).count, vm.count)

        let proxy = ViewModelSpecWithArg3<CounterViewModel, Int, Int, Int>(builder: { _, _, _ in
            let value = CounterViewModel()
            value.count = 100
            return value
        }, key: { _, _, _ in "proxy" })
        base.setProxy(proxy)
        XCTAssertEqual(binding.read(base(1, 2, 3)).count, 100)
        base.clearProxy()
        XCTAssertTrue(binding.read(base(1, 2, 3)) === vm)
        let value = await base.runWithOverride(proxy) {
            await Task.yield()
            return binding.read(base(1, 2, 3)).count
        }
        XCTAssertEqual(value, 100)
        XCTAssertTrue(binding.read(base(1, 2, 3)) === vm)

        let failing = ViewModelSpecWithArg3<CounterViewModel, Int, Int, Int>(throwingBuilder: { _, _, _ in
            throw SpecCoverageError.rejected
        }, key: { _, _, _ in "rejected" })
        XCTAssertThrowsError(try binding.readThrowing(failing(1, 2, 3))) { error in
            XCTAssertTrue(error is SpecCoverageError)
        }
        binding.recycle(vm)
        XCTAssertTrue(vm.isDisposed)
    }

    func test_arg4ThrowingBuilderMetadataProxiesAndTaskLocalOverrides() async throws {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        let base = ViewModelSpecWithArg4<CounterViewModel, Int, Int, Int, Int>(
            throwingBuilder: { a0, a1, a2, a3 in
                let vm = CounterViewModel()
                vm.count = a0 + a1 + a2 + a3
                return vm
            },
            key: { a0, a1, a2, a3 in "base-\(a0 + a1 + a2 + a3)" },
            tag: { a0, a1, a2, a3 in "tag-\(a0 + a1 + a2 + a3)" },
            aliveForever: { _, _, _, _ in true }
        )
        let resolved = base(1, 2, 3, 4)
        let vm = try binding.readThrowing(resolved)
        XCTAssertEqual(vm.count, 10)
        XCTAssertEqual(vm.instanceArg.key, "base-10")
        XCTAssertEqual(vm.tag, "tag-10")
        XCTAssertTrue(vm.instanceArg.aliveForever)

        let wrapped = ViewModelSpec<CounterViewModel>(key: "wrapped") { base.builder(1, 2, 3, 4) }
        XCTAssertEqual(binding.read(wrapped).count, vm.count)

        let proxy = ViewModelSpecWithArg4<CounterViewModel, Int, Int, Int, Int>(builder: { _, _, _, _ in
            let value = CounterViewModel()
            value.count = 100
            return value
        }, key: { _, _, _, _ in "proxy" })
        base.setProxy(proxy)
        XCTAssertEqual(binding.read(base(1, 2, 3, 4)).count, 100)
        base.clearProxy()
        XCTAssertTrue(binding.read(base(1, 2, 3, 4)) === vm)
        let value = await base.runWithOverride(proxy) {
            await Task.yield()
            return binding.read(base(1, 2, 3, 4)).count
        }
        XCTAssertEqual(value, 100)
        XCTAssertTrue(binding.read(base(1, 2, 3, 4)) === vm)

        let failing = ViewModelSpecWithArg4<CounterViewModel, Int, Int, Int, Int>(throwingBuilder: { _, _, _, _ in
            throw SpecCoverageError.rejected
        }, key: { _, _, _, _ in "rejected" })
        XCTAssertThrowsError(try binding.readThrowing(failing(1, 2, 3, 4))) { error in
            XCTAssertTrue(error is SpecCoverageError)
        }
        binding.recycle(vm)
        XCTAssertTrue(vm.isDisposed)
    }
}
