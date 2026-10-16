import Foundation
import XCTest
@testable import DependencyScannerCore

final class ViewModelLintTests: XCTestCase {
    private func lint(_ body: String, disabled: Set<ViewModelLintRule> = []) -> ViewModelLintReport {
        ViewModelLint.scan([ScannerSource(path: "/Feature.swift", text: """
        class Child: ViewModel {}
        let childSpec = ViewModelSpec<Child> { Child() }
        \(body)
        """)], configuration: .init(disabledRules: disabled))
    }

    func testLazyPropertyReportsLocationAndComputedResolverAdvice() throws {
        let warning = try XCTUnwrap(lint("""
        class Parent: ViewModel {
            lazy var child = viewModelBinding.read(childSpec)
        }
        """).warnings.first)
        XCTAssertEqual(warning.rule, .cachedViewModel)
        XCTAssertEqual(warning.location.line, 4)
        XCTAssertEqual(warning.location.column, 22)
        XCTAssertEqual(warning.diagnostic,
            "/Feature.swift:4:22: warning: AppleViewModel [cached-view-model]: Resolved ViewModel stored in 'child' can remain stale after recycle; use a computed property that calls watch/read(spec).")
    }

    func testStoredAssignmentsAndObserversAreChecked() {
        let report = lint("""
        class Host: NSObject {
            var child: Child? { didSet {} }
            init(binding: ViewModelBinding) {
                super.init()
                self.child = binding.watch(childSpec)
                child = try! binding.readThrowing(childSpec)
            }
        }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), [.cachedViewModel, .cachedViewModel])
    }

    func testLocalAndStoredBindingDeclarations() {
        let report = lint("""
        class Host: NSObject {
            let binding = ViewModelBinding()
            let typedBinding: AppleViewModel.ViewModelBinding = .init()
            lazy var first = self.binding.watch(childSpec)
            lazy var second = typedBinding.read(childSpec)
            var child: Child?
            func f() {
                let local = ViewModelBinding()
                self.child = local.read(childSpec)
            }
        }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), Array(repeating: .cachedViewModel, count: 3))
    }

    func testLocalsGettersTransformationsAndUnrelatedReadsAreNotCaching() {
        XCTAssertTrue(lint("""
        class Host: NSObject {
            var child: Child { viewModelBinding.read(childSpec) }
            var explicit: Child { get { viewModelBinding.watch(childSpec) } }
            lazy var title = describe(viewModelBinding.read(childSpec))
            func f(child: Child?) {
                var child = child
                child = viewModelBinding.read(childSpec)
                let temporary = viewModelBinding.watch(childSpec)
            }
            func g(viewModelBinding: OtherReader) {
                self.child = viewModelBinding.read(childSpec)
            }
            lazy var unrelated = unknownReader.read(childSpec)
        }
        """).warnings.isEmpty)
    }

    func testClosureBindingShadowingIsRespected() {
        XCTAssertEqual(lint("""
        class Host: NSObject {
            var child: Child?
            func f() {
                values.forEach { viewModelBinding in self.child = viewModelBinding.read(childSpec) }
                values.forEach { (binding: ViewModelBinding) in self.child = binding.read(childSpec) }
            }
        }
        """).warnings.map(\.rule), [.cachedViewModel])
    }

    func testComputedAccessorsAllowLocalResolvedViewModels() {
        XCTAssertTrue(lint("""
        class Host: NSObject {
            var implicit: Child {
                let session = viewModelBinding.read(childSpec)
                configure(session)
                return session
            }
            var explicit: Child {
                get {
                    let session = viewModelBinding.watch(childSpec)
                    return session
                }
            }
            var throwing: Child {
                get throws {
                    let session = try viewModelBinding.readThrowing(childSpec)
                    return session
                }
            }
            subscript(index: Int) -> Child {
                let session = try! viewModelBinding.watchThrowing(childSpec)
                return session
            }
        }
        """).warnings.isEmpty)
    }

    func testImplicitGetterLocalsDoNotHideStoredAssignmentsOrLeakToOtherMembers() {
        let report = lint("""
        class Host: NSObject {
            var child: Child?
            var resolved: Child? {
                let binding = ViewModelBinding()
                var child: Child?
                child = binding.read(childSpec)
                self.child = binding.watch(childSpec)
                return child
            }
            var unrelated: Child? {
                let viewModelBinding = OtherReader()
                self.child = viewModelBinding.read(childSpec)
                return child
            }
            lazy var cached = viewModelBinding.read(childSpec)
        }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), [.cachedViewModel, .cachedViewModel])
        XCTAssertEqual(report.warnings.map(\.location.line), [9, 17])
    }

    func testLiteralAliveForeverWithoutKeyAndTypedInit() {
        let report = lint("""
        let a = ViewModelSpec<Child>(aliveForever: true) { Child() }
        let b = AppleViewModel.ViewModelSpec<Child>(key: nil, aliveForever: true) { Child() }
        let c: ViewModelSpec<Child>? = .init(aliveForever: true, builder: { Child() })
        let d: ViewModelSpec<Child>! = .init(key: nil, aliveForever: true, throwingBuilder: { Child() })
        """)
        XCTAssertEqual(report.warnings.map(\.rule), Array(repeating: .aliveForeverKey, count: 4))
    }

    func testExplicitKeysAndUnknownAliveForeverExpressionsAreNotRejected() {
        XCTAssertTrue(lint("""
        let a = ViewModelSpec<Child>(key: "child", aliveForever: true) { Child() }
        let b = ViewModelSpec<Child>(aliveForever: false) { Child() }
        let c = ViewModelSpec<Child>(aliveForever: configuration.keepAlive) { Child() }
        let d = ViewModelSpecWithArg<Child, String>(builder: { _ in Child() }, key: { $0 })
        let e = ViewModelSpecWithArg<Child, String>(builder: { _ in Child() }, key: { _ in "shared" })
        """).warnings.isEmpty)
    }

    func testAllParameterizedSpecAritiesAllowMissingKeys() {
        let report = lint("""
        let a = ViewModelSpecWithArg<Child, String>(builder: { _ in Child() })
        let b = ViewModelSpecWithArg2<Child, Int, Int>(builder: { _, _ in Child() }, key: nil)
        let c = ViewModelSpecWithArg3<Child, Int, Int, Int>(builder: { _, _, _ in Child() })
        let d: AppleViewModel.ViewModelSpecWithArg4<Child, Int, Int, Int, Int> = .init(builder: { _, _, _, _ in Child() })
        """)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testConstantClosuresAndAdditionalTrailingClosures() {
        let report = lint("""
        let a = ViewModelSpecWithArg<Child, Int>(builder: { _ in Child() }, key: { _ in nil }, aliveForever: { _ in return true })
        let b = ViewModelSpecWithArg<Child, Int> { _ in Child() } key: { _ in nil } aliveForever: { _ in true }
        let c = ViewModelSpecWithArg<Child, Int>(builder: { _ in Child() }, key: { id in log(id); return makeKey(id) }, aliveForever: { id in log(id); return true })
        """)
        XCTAssertEqual(report.warnings.map(\.rule), [
            .aliveForeverKey, .aliveForeverKey
        ])
    }

    func testNamedAndContextualDirectConstructorsAreReported() {
        let report = lint("""
        let a = Child()
        let b = Child.init()
        let c: Child = .init()
        func helper() -> Child { Child() }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), Array(repeating: .unmanagedConstruction, count: 4))
    }

    func testBuildersAndFactoryMethodsPermitConstruction() {
        XCTAssertTrue(lint("""
        let a = ViewModelSpec<Child>(builder: { Child() })
        let b = ViewModelSpec<Child>(throwingBuilder: { Child() })
        let c = ViewModelSpec<Child>.init { Child() }
        class Factory: ViewModelFactory {
            typealias VM = Child
            func build() -> Child { Child() }
            func buildThrowing() throws -> Child { Child() }
        }
        class DerivedFactory: Factory {
            override func build() -> Child { Child() }
        }
        class ExtendedFactory {}
        extension ExtendedFactory: AppleViewModel.ViewModelFactory {
            typealias VM = Child
            func build() -> Child { Child() }
        }
        """).warnings.isEmpty)
    }

    func testFactoryLikeNamesAndKeyClosuresDoNotExemptConstruction() {
        let report = lint("""
        class NotAFactory { func build() -> Child { Child() } }
        extension NotAFactory { func buildThrowing() throws -> Child { Child() } }
        class Factory: ViewModelFactory {
            func build() -> Child { Child() }
            func build(argument: Int) -> Child { Child() }
            static func buildThrowing() throws -> Child { Child() }
        }
        let a = ViewModelSpecWithArg<Child, Int>(builder: { _ in Child() }, key: { _ in
            let unmanaged = Child()
            return "key"
        })
        """)
        XCTAssertEqual(report.warnings.map(\.rule), Array(repeating: .unmanagedConstruction, count: 5))
    }

    func testDelegatingInitializersShadowedConstructorsAndUnknownTypes() {
        XCTAssertTrue(lint("""
        class Other: NSObject { override init() { super.init() }; convenience init(x: Int) { self.init() } }
        func f(Child: () -> Child) { let value = Child() }
        func g() { let Child = makeClosure(); let value = Child() }
        func h() { unknown(.init()) }
        let unknown = ExternalViewModel()
        """).warnings.isEmpty)
    }

    func testSameNamedUserSpecTypesAreNotFrameworkSpecs() {
        XCTAssertTrue(lint("""
        enum Feature {
            struct ViewModelSpec<T> {}
            let value = ViewModelSpec<Int>(aliveForever: true)
        }
        """).warnings.isEmpty)
    }

    func testRulesCanBeDisabledIndependentlyIncludingCycles() {
        let source = """
        class Parent: ViewModel {
            static let spec = ViewModelSpec<Parent> { Parent() }
            lazy var cached = viewModelBinding.read(Self.spec)
        }
        let a = Child()
        let b = ViewModelSpecWithArg<Child, Int>(builder: { _ in Child() }, aliveForever: { _ in true })
        """
        let report = lint(source)
        XCTAssertEqual(report.cycles.count, 1)
        XCTAssertEqual(Set(report.warnings.map(\.rule)), Set(ViewModelLintRule.allCases).subtracting([.dependencyCycle]))
        for rule in ViewModelLintRule.allCases {
            let filtered = lint(source, disabled: [rule])
            XCTAssertFalse(filtered.warnings.contains { $0.rule == rule })
            XCTAssertEqual(filtered.cycles.count, rule == .dependencyCycle ? 0 : 1)
            XCTAssertEqual(filtered.warnings.count, rule == .dependencyCycle ? 3 : 2)
        }
        let disabled = lint(source, disabled: Set(ViewModelLintRule.allCases))
        XCTAssertTrue(disabled.warnings.isEmpty)
        XCTAssertTrue(disabled.cycles.isEmpty)
    }

    func testConfigurationDecodingRejectsUnknownRulesAndInvalidJSON() throws {
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode(ViewModelLintConfiguration.self, from: Data("{}".utf8)).disabledRules.isEmpty)
        let config = try decoder.decode(ViewModelLintConfiguration.self, from: Data(#"{"disabledRules":["cached-view-model","parameterized-spec-key"]}"#.utf8))
        XCTAssertEqual(config.disabledRules, [.cachedViewModel])
        XCTAssertThrowsError(try decoder.decode(ViewModelLintConfiguration.self, from: Data(#"{"disabledRules":["typo"]}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(ViewModelLintConfiguration.self, from: Data("invalid".utf8)))
    }

    func testInvocationCompatibilityAndValidation() throws {
        let legacy = try ScannerInvocation(arguments: ["--output", "/out.swift", "/Source with spaces.swift"])
        XCTAssertFalse(legacy.lint)
        XCTAssertNil(legacy.configurationPath)
        XCTAssertEqual(legacy.output, "/out.swift")
        XCTAssertEqual(legacy.sources, ["/Source with spaces.swift"])
        let lint = try ScannerInvocation(arguments: ["--lint", "--config", "/config.json", "--output", "/out.swift"])
        XCTAssertTrue(lint.lint)
        XCTAssertEqual(lint.configurationPath, "/config.json")
        for args in [[], ["--output"], ["--output", "--lint"], ["--output", "/out", "--bad"], ["--output", "/out", "--config", "/config"]] {
            XCTAssertThrowsError(try ScannerInvocation(arguments: args)) { error in
                XCTAssertTrue(String(describing: error).contains("usage:"))
            }
        }
    }

    func testCrossFileFactoryConformanceAndStableDiagnosticOrder() {
        let sources = [
            ScannerSource(path: "/Factory.swift", text: """
            class Child: ViewModel {}
            class Factory { func build() -> Child { Child() } }
            class Derived: Factory { override func build() -> Child { Child() } }
            struct Unrelated: Sendable {}
            let direct = Child()
            """),
            ScannerSource(path: "/Conformance.swift", text: "extension Factory: ViewModelFactory { typealias VM = Child }"),
            ScannerSource(path: "/Other.swift", text: "let directOther = Child()")
        ]
        let warnings = ViewModelLint.scan(sources).warnings
        XCTAssertEqual(warnings.map(\.rule), [.unmanagedConstruction, .unmanagedConstruction])
        XCTAssertEqual(warnings.map(\.location.path), ["/Factory.swift", "/Other.swift"])
        XCTAssertEqual(warnings, ViewModelLint.scan(sources.reversed()).warnings)
    }

    func testExternalFactoryExtensionsAndNestedBuildFunctions() {
        let report = lint("""
        extension ExternalFactory: ViewModelFactory {
            func build() -> Child { Child() }
        }
        extension OtherExternal: OtherProtocol {
            func build() -> Child { Child() }
        }
        class Factory: ViewModelFactory {
            func build() -> Child { Child() }
            func start() -> Child {
                func build() -> Child { Child() }
                return build()
            }
        }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), [.unmanagedConstruction, .unmanagedConstruction])
    }

    func testClosureLocalsShadowConstructorsBindingsAndStoredDestinations() {
        let report = lint("""
        class Host {
            var child: Child?
            func f() {
                run {
                    let Child = makeClosure()
                    _ = Child()
                    let viewModelBinding = OtherReader()
                    self.child = viewModelBinding.read(childSpec)
                }
                run {
                    let binding = ViewModelBinding()
                    self.child = binding.read(childSpec)
                    var child: Child?
                    child = binding.read(childSpec)
                }
            }
        }
        """)
        XCTAssertEqual(report.warnings.map(\.rule), [.cachedViewModel])
        XCTAssertEqual(report.warnings.first?.location.line, 14)
    }
}
