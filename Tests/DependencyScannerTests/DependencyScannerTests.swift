import XCTest
@testable import DependencyScannerCore

final class DependencyScannerTests: XCTestCase {
    private func scan(_ text: String) -> [DependencyCycle] {
        DependencyScanner.scan([ScannerSource(path: "/Fixture.swift", text: text)])
    }

    func testCrossFileCycleIncludesExactLocationsAndWarning() throws {
        let sources = [
            ScannerSource(path: "/A.swift", text: """
            let bSpec = ViewModelSpec<B> { B() }
            final class A: ViewModel {
                var b: B { viewModelBinding.read(bSpec) }
            }
            """),
            ScannerSource(path: "/B.swift", text: """
            let aSpec = ViewModelSpec<A> { A() }
            final class B: ViewModel {
                var a: A { self.viewModelBinding.watch(aSpec) }
            }
            """)
        ]
        let cycle = try XCTUnwrap(DependencyScanner.scan(sources).first)
        XCTAssertEqual(cycle.path, "A -> B -> A")
        XCTAssertEqual(cycle.edges.map(\.location.line), [3, 3])
        XCTAssertEqual(cycle.edges.map(\.location.column), [16, 16])
        XCTAssertEqual(cycle.diagnostics, [
            "/A.swift:3:16: warning: AppleViewModel: potential dependency cycle: A -> B -> A",
            "/A.swift:3:16: note: A -> B resolved here",
            "/B.swift:3:16: note: B -> A resolved here"
        ])
        XCTAssertEqual(DependencyScanner.scan(sources), DependencyScanner.scan(sources.reversed()))
    }

    func testAcyclicDiamondDoesNotWarn() {
        XCTAssertTrue(scan("""
        let b = ViewModelSpec<B> { B() }
        let c = ViewModelSpec<C> { C() }
        let d = ViewModelSpec<D> { D() }
        class A: ViewModel {
            var left: B { viewModelBinding.watch(b) }
            var right: C { viewModelBinding.read(c) }
        }
        class B: ViewModel { var leaf: D { viewModelBinding.read(d) } }
        class C: ViewModel { var leaf: D { viewModelBinding.read(d) } }
        class D: ViewModel {}
        """).isEmpty)
    }

    func testSelfCycleAndDuplicateEdgesAreReportedOnce() {
        let cycles = scan("""
        let a = ViewModelSpec<A>(key: "other") { A() }
        class A: ViewModel {
            var first: A { viewModelBinding.read(a) }
            var second: A { viewModelBinding.watch(a) }
        }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> A"])
        XCTAssertEqual(cycles.first?.edges.first?.location.line, 3)
    }

    func testLongCycleThrowingCallsAndArgSpecs() {
        let cycles = scan("""
        let a = ViewModelSpecWithArg<A, String>(builder: { A($0) })
        let b = ViewModelSpecWithArg2<B, Int, Int>(builder: { B($0, $1) })
        let c = ViewModelSpecWithArg4<C, Int, Int, Int, Int>(builder: { C() })
        class A: ViewModel { func resolve() throws { _ = try viewModelBinding.readThrowing(b(1, 2)) } }
        class B: ViewModel { func resolve() throws { _ = try viewModelBinding.watchThrowing(c(1, 2, 3, 4)) } }
        class C: ViewModel { var aValue: A { viewModelBinding.read(a("id")) } }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> B -> C -> A"])
    }

    func testAnnotationsInferredBuildersInlineSpecsAndExtensions() {
        let cycles = scan("""
        enum Specs {
            static let a: ViewModelSpec<A> = .init { A() }
            static let b = ViewModelSpec { B() }
        }
        class A: ViewModel {}
        extension A { var b: B { viewModelBinding.read(Specs.b) } }
        class B: ViewModel { var a: A { viewModelBinding.watch(Specs.a) } }
        class C: ViewModel {
            var itself: C { viewModelBinding.read(AppleViewModel.ViewModelSpec<C> { C() }) }
        }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> B -> A", "C -> C"])
    }

    func testNestedTypesSelfSpecsAndTransitiveViewModelSubclass() {
        let cycles = scan("""
        class Base: AppleViewModel.StateViewModel<Int> {}
        enum Feature {
            class A: Base {
                static let bSpec = ViewModelSpec<B> { B() }
                var b: B { viewModelBinding.read(Self.bSpec) }
            }
            class B: ViewModel {
                let aSpec: AppleViewModel.ViewModelSpec<A>
                var a: A { viewModelBinding.watch(self.aSpec) }
            }
        }
        """)
        XCTAssertEqual(cycles.map(\.path), ["Feature.A -> Feature.B -> Feature.A"])
    }

    func testNonVMsOtherBindingsStaticMembersCommentsAndStringsAreIgnored() {
        XCTAssertTrue(scan(#"""
        let a = ViewModelSpec<A> { A() }
        class A: ViewModel {
            static func f() { viewModelBinding.read(a) }
            class var shared: A { viewModelBinding.read(a) }
            var independent: A { otherBinding.read(a) }
            var text: String { "viewModelBinding.read(a)" }
            // var recursive: A { viewModelBinding.read(a) }
            struct Nested { var value: A { viewModelBinding.read(a) } }
        }
        class Other { var value: Other { viewModelBinding.read(ViewModelSpec<Other> { Other() }) } }
        """#).isEmpty)
    }

    func testLocalSpecAndTypedParameterUseLexicalType() {
        let cycles = scan("""
        let spec = ViewModelSpec<B> { B() }
        class A: ViewModel {
            func resolve() {
                let spec = ViewModelSpec<A> { A() }
                _ = viewModelBinding.read(spec)
            }
        }
        class B: ViewModel {
            func resolve(spec: ViewModelSpec<B>) { _ = viewModelBinding.read(spec) }
        }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> A", "B -> B"])
    }

    func testUnresolvedShadowDoesNotFallBackToGlobalSpec() {
        XCTAssertTrue(scan("""
        let spec = ViewModelSpec<A> { A() }
        class A: ViewModel {
            func resolve(spec: any ViewModelFactory<B>) { _ = viewModelBinding.read(spec) }
            func other() {
                let spec = makeSpec()
                _ = viewModelBinding.read(spec)
            }
        }
        class B: ViewModel {}
        """).isEmpty)
    }

    func testImplicitGetterSpecsUseLexicalScope() {
        let cycles = scan("""
        let spec = ViewModelSpec<B> { B() }
        class A: ViewModel {
            var first: A {
                let spec = ViewModelSpec<A> { A() }
                return viewModelBinding.read(spec)
            }
            var second: A {
                let spec: ViewModelSpec<A> = .init { A() }
                return viewModelBinding.watch(spec)
            }
        }
        class B: ViewModel {}
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> A"])
        XCTAssertEqual(cycles.first?.edges.first?.location.line, 5)
    }

    func testImplicitGetterShadowsStayLocal() {
        XCTAssertTrue(scan("""
        let spec = ViewModelSpec<B> { B() }
        let selfSpec = ViewModelSpec<A> { A() }
        class A: ViewModel {
            var localSpec: ViewModelSpec<A> {
                let spec = ViewModelSpec<A> { A() }
                return spec
            }
            var global: B { viewModelBinding.read(spec) }
            var unknown: B {
                let selfSpec = makeSpec()
                return viewModelBinding.read(selfSpec)
            }
            var independent: A {
                let viewModelBinding = ViewModelBinding()
                return viewModelBinding.read(selfSpec)
            }
        }
        class B: ViewModel {}
        """).isEmpty)
    }

    func testAmbiguousDeclarationsAreNotGuessed() {
        let files = [
            ScannerSource(path: "/One.swift", text: "private let spec = ViewModelSpec<A> { A() }"),
            ScannerSource(path: "/Two.swift", text: "private let spec = ViewModelSpec<B> { B() }"),
            ScannerSource(path: "/Types.swift", text: """
            class A: ViewModel { var value: A { viewModelBinding.read(spec) } }
            class B: ViewModel {}
            """)
        ]
        XCTAssertTrue(DependencyScanner.scan(files).isEmpty)
    }

    func testSeparateNamespacesDoNotCollapseSameNamedTypes() {
        let cycles = scan("""
        enum One {
            static let spec = ViewModelSpec<A> { A() }
            class A: ViewModel { var value: A { viewModelBinding.read(One.spec) } }
        }
        enum Two {
            static let spec = ViewModelSpec<A> { A() }
            class A: ViewModel {}
        }
        """)
        XCTAssertEqual(cycles.map(\.path), ["One.A -> One.A"])
    }

    func testOverlappingAndDisconnectedCyclesHaveDeterministicWitnesses() {
        let cycles = scan("""
        let a = ViewModelSpec<A> { A() }
        let b = ViewModelSpec<B> { B() }
        let c = ViewModelSpec<C> { C() }
        let d = ViewModelSpec<D> { D() }
        class A: ViewModel { var bValue: B { viewModelBinding.read(b) } }
        class B: ViewModel {
            var aValue: A { viewModelBinding.read(a) }
            var cValue: C { viewModelBinding.read(c) }
        }
        class C: ViewModel { var aValue: A { viewModelBinding.read(a) } }
        class D: ViewModel { var value: D { viewModelBinding.read(d) } }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> B -> A", "A -> B -> C -> A", "D -> D"])
    }

    func testConditionalBranchesArePotentialDependencies() {
        XCTAssertEqual(scan("""
        let a = ViewModelSpec<A> { A() }
        class A: ViewModel {
            #if FEATURE
            var value: A { viewModelBinding.read(a) }
            #endif
        }
        """).map(\.path), ["A -> A"])
    }

    func testNamedBuilderInferenceAndRepeatedCallsOnSameLine() {
        let cycles = scan("""
        let spec = ViewModelSpec(builder: { return A() })
        class A: ViewModel { func f() { _ = viewModelBinding.read(spec); _ = viewModelBinding.watch(spec) } }
        """)
        XCTAssertEqual(cycles.map(\.path), ["A -> A"])
        XCTAssertEqual(cycles.first?.edges.first?.location.column, 37)
    }

    func testUnknownAndDynamicSpecExpressionsAreSkipped() {
        XCTAssertTrue(scan("""
        let typed = ViewModelSpec<A>(builder: makeA)
        class A: ViewModel {
            func f() {
                _ = viewModelBinding.read(missingSpec)
                _ = viewModelBinding.read(specs[0])
                _ = viewModelBinding.read(makeSpec())
                _ = viewModelBinding.read(ViewModelSpec(builder: makeA))
            }
        }
        func outsideAViewModel() { _ = viewModelBinding.read(typed) }
        """).isEmpty)
    }

    func testClosureParametersAndBindingParametersShadowOuterNames() {
        XCTAssertTrue(scan("""
        let spec = ViewModelSpec<A> { A() }
        class A: ViewModel {
            func f(viewModelBinding: ViewModelBinding) { _ = viewModelBinding.read(spec) }
            func g() {
                specs.forEach { spec in _ = viewModelBinding.read(spec) }
                specs.forEach { (spec: ViewModelSpec<B>) in _ = viewModelBinding.read(spec) }
            }
            class Local: ViewModel {}
            func nested() {
                class Local: ViewModel {
                    var value: Local { viewModelBinding.read(ViewModelSpec<Local> { Local() }) }
                }
            }
        }
        class B: ViewModel {}
        """).isEmpty)
    }

    func testLocalAnnotatedSpecsAndUnknownBaseClasses() {
        XCTAssertEqual(scan("""
        let inferred = ViewModelSpec(key: "a", throwingBuilder: { A() })
        class A: ViewModel {
            func f() {
                let spec: ViewModelSpec<A> = .init { A() }
                _ = viewModelBinding.read(spec)
            }
        }
        class Host: NSObject {
            var value: A { viewModelBinding.read(inferred) }
        }
        """).map(\.path), ["A -> A"])
    }

    func testClosureLocalDeclarationsShadowGlobalSpecsAndBindings() {
        XCTAssertTrue(scan("""
        let spec = ViewModelSpec<A> { A() }
        class A: ViewModel {
            func f() {
                run {
                    let spec = ViewModelSpec<B> { B() }
                    _ = viewModelBinding.read(spec)
                }
                run {
                    let viewModelBinding = ViewModelBinding()
                    _ = viewModelBinding.read(spec)
                }
            }
        }
        class B: ViewModel {}
        """).isEmpty)
    }

    func testExplicitBuilderTakesPrecedenceOverTrailingConfigurationClosure() {
        XCTAssertEqual(scan("""
        let spec = ViewModelSpecWithArg(builder: { (_: Int) in A() }, key: { $0 }) { _ in true }
        let dynamic = ViewModelSpecWithArg(builder: makeSpec) { _ in true }
        class A: ViewModel {
            var value: A { viewModelBinding.read(spec(1)) }
        }
        class B: ViewModel {
            var value: A { viewModelBinding.read(dynamic(1)) }
        }
        """).map(\.path), ["A -> A"])
    }
}
