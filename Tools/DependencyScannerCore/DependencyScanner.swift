import SwiftParser
import SwiftSyntax

public struct ScannerSource {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct DependencyLocation: Equatable {
    public let path: String
    public let line: Int
    public let column: Int

    public var diagnosticPrefix: String { "\(path):\(line):\(column)" }
}

public struct DependencyEdge: Equatable {
    public let source: String
    public let target: String
    public let location: DependencyLocation
}

public struct DependencyCycle: Equatable {
    public let edges: [DependencyEdge]

    public var path: String {
        (edges.map(\.source) + [edges.last!.target]).joined(separator: " -> ")
    }

    public var diagnostics: [String] {
        ["\(edges[0].location.diagnosticPrefix): warning: AppleViewModel: potential dependency cycle: \(path)"]
            + edges.map {
                "\($0.location.diagnosticPrefix): note: \($0.source) -> \($0.target) resolved here"
            }
    }
}

/// Source-only, target-local analysis. Edges represent possible type dependencies,
/// not runtime instance identity or proof that a getter will execute.
public enum DependencyScanner {
    public static func scan(_ sources: [ScannerSource]) -> [DependencyCycle] {
        let files = sources.sorted { $0.path < $1.path }.map(ParsedFile.init)
        let index = DeclarationIndex(files: files)
        return scan(files: files, index: index)
    }

    static func scan(files: [ParsedFile], index: DeclarationIndex) -> [DependencyCycle] {
        var graph: [String: [GraphEdge]] = [:]
        for file in files {
            let visitor = ResolutionVisitor(file: file, index: index)
            visitor.walk(file.tree)
            for edge in visitor.edges { graph[edge.source.id, default: []].append(edge) }
        }
        return cycles(in: graph)
    }

    // Deterministic DFS back edges yield cycle witnesses without enumerating an
    // exponential number of simple cycles in dense graphs.
    private static func cycles(in graph: [String: [GraphEdge]]) -> [DependencyCycle] {
        var complete: Set<String> = []
        var active: [String: Int] = [:]
        var path: [GraphEdge] = []
        var result: [DependencyCycle] = []

        func visit(_ node: String) {
            guard !complete.contains(node) else { return }
            active[node] = path.count
            var seenTargets: Set<String> = []
            let edges = (graph[node] ?? []).sorted {
                if $0.target.id != $1.target.id { return $0.target.id < $1.target.id }
                if $0.location.path != $1.location.path { return $0.location.path < $1.location.path }
                if $0.location.line != $1.location.line { return $0.location.line < $1.location.line }
                return $0.location.column < $1.location.column
            }
            for edge in edges where seenTargets.insert(edge.target.id).inserted {
                if let start = active[edge.target.id] {
                    result.append(DependencyCycle(edges: (Array(path[start...]) + [edge]).map {
                        DependencyEdge(source: $0.source.name, target: $0.target.name, location: $0.location)
                    }))
                } else if !complete.contains(edge.target.id) {
                    path.append(edge)
                    visit(edge.target.id)
                    path.removeLast()
                }
            }
            active[node] = nil
            complete.insert(node)
        }

        for node in graph.keys.sorted() { visit(node) }
        return result
    }
}

struct ParsedFile {
    let path: String
    let tree: SourceFileSyntax
    let locations: SourceLocationConverter

    init(_ source: ScannerSource) {
        path = source.path
        tree = Parser.parse(source: source.text)
        locations = SourceLocationConverter(fileName: path, tree: tree)
    }

    func location(_ node: some SyntaxProtocol) -> DependencyLocation {
        let value = locations.location(for: node.positionAfterSkippingLeadingTrivia)
        return DependencyLocation(path: path, line: value.line, column: value.column)
    }
}

struct TypeDeclaration {
    let name: String
    let file: String
    var bases: [String]
    var isClass = true
    var id: String { file + "#" + name }
}

struct SpecTarget {
    let name: String
    let scope: String
    let file: String
}

struct SpecDeclaration {
    let name: String
    let file: String
    let target: SpecTarget?
    let type: TypeSyntax?
    let initializer: ExprSyntax?
    let isStored: Bool
}

private struct GraphEdge {
    let source: TypeDeclaration
    let target: TypeDeclaration
    let location: DependencyLocation
}

final class DeclarationIndex {
    var types: [String: [TypeDeclaration]] = [:]
    var specs: [String: [SpecDeclaration]] = [:]
    var viewModels: Set<String> = []
    var factories: Set<String> = []

    init(files: [ParsedFile]) {
        var extensions: [(name: String, file: String, bases: [String])] = []
        for file in files {
            let visitor = DeclarationVisitor(file: file)
            visitor.walk(file.tree)
            for type in visitor.types { types[type.name, default: []].append(type) }
            for spec in visitor.specs { specs[spec.name, default: []].append(spec) }
            extensions.append(contentsOf: visitor.extensions)
        }
        for ext in extensions {
            guard let type = resolveType(ext.name, scope: "", file: ext.file),
                  let position = types[type.name]?.firstIndex(where: { $0.id == type.id }) else { continue }
            types[type.name]?[position].bases.append(contentsOf: ext.bases)
        }
        // Fixed point also recognizes subclasses of locally declared VM bases.
        var changed = true
        while changed {
            changed = false
            for type in types.values.flatMap({ $0 }) {
                let isVM = type.isClass && type.bases.contains { base in
                    if ["ViewModel", "StateViewModel", "AppleViewModel.ViewModel", "AppleViewModel.StateViewModel"]
                        .contains(base) { return true }
                    return resolveType(base, scope: parentScope(type.name), file: type.file)
                        .map { viewModels.contains($0.id) } ?? false
                }
                if isVM, viewModels.insert(type.id).inserted { changed = true }
                let isFactory = type.bases.contains { base in
                    if ["ViewModelFactory", "AppleViewModel.ViewModelFactory"].contains(base) { return true }
                    return resolveType(base, scope: parentScope(type.name), file: type.file)
                        .map { factories.contains($0.id) } ?? false
                }
                if isFactory, factories.insert(type.id).inserted { changed = true }
            }
        }
    }

    func resolveType(_ name: String, scope: String, file: String) -> TypeDeclaration? {
        for candidate in candidates(name, scope: scope) {
            guard let matches = types[candidate] else { continue }
            let local = matches.filter { $0.file == file }
            if local.count == 1 { return local[0] }
            return matches.count == 1 ? matches[0] : nil
        }
        return nil
    }

    func resolveSpec(_ name: String, scope: String, file: String) -> SpecTarget? {
        resolveValue(name, scope: scope, file: file)?.target
    }

    func resolveValue(_ name: String, scope: String, file: String) -> SpecDeclaration? {
        for candidate in candidates(name, scope: scope) {
            guard let matches = specs[candidate] else { continue }
            let local = matches.filter { $0.file == file }
            if local.count == 1 { return local[0] }
            return matches.count == 1 ? matches[0] : nil
        }
        return nil
    }
}

private final class DeclarationVisitor: SyntaxVisitor {
    let file: ParsedFile
    var types: [TypeDeclaration] = []
    var specs: [SpecDeclaration] = []
    var extensions: [(name: String, file: String, bases: [String])] = []

    init(file: ParsedFile) {
        self.file = file
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isLocal(node) else { return .skipChildren }
        types.append(TypeDeclaration(
            name: qualified(scope(of: node), node.name.text), file: file.path,
            bases: node.inheritanceClause?.inheritedTypes.compactMap { typeName($0.type) } ?? []
        ))
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isLocal(node) else { return .skipChildren }
        types.append(TypeDeclaration(
            name: qualified(scope(of: node), node.name.text), file: file.path,
            bases: node.inheritanceClause?.inheritedTypes.compactMap { typeName($0.type) } ?? [], isClass: false
        ))
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let name = typeName(node.extendedType), let inheritance = node.inheritanceClause {
            extensions.append((name, file.path, inheritance.inheritedTypes.compactMap { typeName($0.type) }))
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isLocal(node) else { return .visitChildren }
        let context = scope(of: node)
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            let target = binding.typeAnnotation.flatMap { specType($0.type) }
                ?? binding.initializer.flatMap { specConstruction($0.value) }
            specs.append(SpecDeclaration(
                name: qualified(context, name), file: file.path,
                target: target.map { SpecTarget(name: $0, scope: context, file: file.path) },
                type: binding.typeAnnotation?.type, initializer: binding.initializer?.value,
                isStored: isStoredProperty(binding)
            ))
        }
        return .visitChildren
    }
}

private final class ResolutionVisitor: SyntaxVisitor {
    let file: ParsedFile
    let index: DeclarationIndex
    var edges: [GraphEdge] = []

    init(file: ParsedFile, index: DeclarationIndex) {
        self.file = file
        self.index = index
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        isLocal(node) ? .skipChildren : .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              ["read", "watch", "readThrowing", "watchThrowing"].contains(member.declName.baseName.text),
              let receiver = member.base.flatMap(expressionName),
              ["viewModelBinding", "self.viewModelBinding"].contains(receiver),
              let argument = node.arguments.first, argument.label == nil,
              isInstanceContext(node) else { return .visitChildren }
        let context = scope(of: node)
        if receiver == "viewModelBinding", localTarget(receiver, at: node, scope: context).found {
            return .visitChildren
        }
        guard let source = index.resolveType(context, scope: "", file: file.path),
              index.viewModels.contains(source.id),
              let spec = target(of: argument.expression, at: node, scope: context),
              let destination = index.resolveType(spec.name, scope: spec.scope, file: spec.file),
              index.viewModels.contains(destination.id) else { return .visitChildren }
        edges.append(GraphEdge(source: source, target: destination, location: file.location(node)))
        return .visitChildren
    }

    private func target(of expression: ExprSyntax, at call: FunctionCallExprSyntax, scope: String) -> SpecTarget? {
        if let name = specConstruction(expression) {
            return SpecTarget(name: name, scope: scope, file: file.path)
        }
        // Applying an arg spec keeps its declared ViewModel type.
        let reference = expression.as(FunctionCallExprSyntax.self)?.calledExpression ?? expression
        guard let name = expressionName(reference) else { return nil }
        if !name.contains(".") {
            let local = localTarget(name, at: call, scope: scope)
            if local.found { return local.target }
        }
        return index.resolveSpec(name, scope: scope, file: file.path)
    }

    // Prefer lexical bindings over global specs; an unresolved local shadow must
    // not accidentally create an edge using an unrelated global declaration.
    private func localTarget(_ name: String, at call: FunctionCallExprSyntax, scope: String)
        -> (found: Bool, target: SpecTarget?) {
        var ancestor = Syntax(call).parent
        while let node = ancestor {
            let statements = node.as(CodeBlockSyntax.self)?.statements
                ?? node.as(ClosureExprSyntax.self)?.statements
            if let statements {
                for item in statements.reversed() where item.position < call.position {
                    guard let declaration = item.item.as(VariableDeclSyntax.self) else { continue }
                    for binding in declaration.bindings {
                        guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name else { continue }
                        let type = binding.typeAnnotation.flatMap { specType($0.type) }
                            ?? binding.initializer.flatMap { specConstruction($0.value) }
                        return (true, type.map { SpecTarget(name: $0, scope: scope, file: file.path) })
                    }
                }
            }
            let parameters: FunctionParameterListSyntax?
            if let function = node.as(FunctionDeclSyntax.self) { parameters = function.signature.parameterClause.parameters }
            else if let initializer = node.as(InitializerDeclSyntax.self) { parameters = initializer.signature.parameterClause.parameters }
            else { parameters = nil }
            if let parameter = parameters?.first(where: { ($0.secondName ?? $0.firstName).text == name }) {
                return (true, specType(parameter.type).map { SpecTarget(name: $0, scope: scope, file: file.path) })
            }
            if let closure = node.as(ClosureExprSyntax.self), let clause = closure.signature?.parameterClause {
                if let parameters = clause.as(ClosureShorthandParameterListSyntax.self),
                   parameters.contains(where: { $0.name.text == name }) { return (true, nil) }
                if let parameters = clause.as(ClosureParameterClauseSyntax.self),
                   let parameter = parameters.parameters.first(where: { ($0.secondName ?? $0.firstName).text == name }) {
                    return (true, parameter.type.flatMap(specType).map {
                        SpecTarget(name: $0, scope: scope, file: file.path)
                    })
                }
            }
            ancestor = node.parent
        }
        return (false, nil)
    }
}

private let specNames: Set<String> = [
    "ViewModelSpec", "ViewModelSpecWithArg", "ViewModelSpecWithArg2",
    "ViewModelSpecWithArg3", "ViewModelSpecWithArg4"
]

func isSpec(_ name: String) -> Bool {
    specNames.contains(name) || (name.hasPrefix("AppleViewModel.") && specNames.contains(String(name.dropFirst(15))))
}

private func specType(_ type: TypeSyntax) -> String? {
    if let optional = type.as(OptionalTypeSyntax.self) { return specType(optional.wrappedType) }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return specType(optional.wrappedType) }
    guard let name = typeName(type), isSpec(name) else { return nil }
    let arguments = type.as(IdentifierTypeSyntax.self)?.genericArgumentClause
        ?? type.as(MemberTypeSyntax.self)?.genericArgumentClause
    return arguments?.arguments.first.flatMap { typeName($0.argument) }
}

private func specConstruction(_ expression: ExprSyntax) -> String? {
    guard let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
    var callee = call.calledExpression
    if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
       let base = member.base { callee = base }
    guard let name = expressionName(callee), isSpec(name) else { return nil }
    if let generic = callee.as(GenericSpecializationExprSyntax.self) {
        return generic.genericArgumentClause.arguments.first.flatMap { typeName($0.argument) }
    }
    // Only infer the obvious single-constructor builder. Never execute a builder
    // or guess the return type of an arbitrary factory function.
    let builderArgument = call.arguments.first(where: {
        $0.label?.text == "builder" || $0.label?.text == "throwingBuilder"
    })
    // With an explicit builder argument, a trailing closure belongs to another
    // parameter (key/tag/aliveForever), not to the ViewModel factory.
    let builder: ClosureExprSyntax?
    if let builderArgument {
        builder = builderArgument.expression.as(ClosureExprSyntax.self)
    } else {
        builder = call.trailingClosure
    }
    guard let builder, builder.statements.count == 1, let statement = builder.statements.first else { return nil }
    let value = statement.item.as(ExprSyntax.self) ?? statement.item.as(ReturnStmtSyntax.self)?.expression
    guard let constructor = value?.as(FunctionCallExprSyntax.self) else { return nil }
    return expressionName(constructor.calledExpression)
}

func typeName(_ type: some SyntaxProtocol) -> String? {
    if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
    if let member = type.as(MemberTypeSyntax.self), let base = typeName(member.baseType) {
        return qualified(base, member.name.text)
    }
    return nil
}

func expressionName(_ expression: ExprSyntax) -> String? {
    if let identifier = expression.as(DeclReferenceExprSyntax.self) { return identifier.baseName.text }
    if let generic = expression.as(GenericSpecializationExprSyntax.self) { return expressionName(generic.expression) }
    if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base.flatMap(expressionName) {
        return qualified(base, member.declName.baseName.text)
    }
    return nil
}

func scope(of node: some SyntaxProtocol) -> String {
    var names: [String] = []
    var ancestor = Syntax(node).parent
    while let parent = ancestor {
        if let name = scopeName(parent) { names.append(name) }
        ancestor = parent.parent
    }
    return names.reversed().joined(separator: ".")
}

func scopeName(_ node: Syntax) -> String? {
    if let value = node.as(ClassDeclSyntax.self) { return value.name.text }
    if let value = node.as(StructDeclSyntax.self) { return value.name.text }
    if let value = node.as(EnumDeclSyntax.self) { return value.name.text }
    if let value = node.as(ActorDeclSyntax.self) { return value.name.text }
    if let value = node.as(ProtocolDeclSyntax.self) { return value.name.text }
    if let value = node.as(ExtensionDeclSyntax.self) { return typeName(value.extendedType) }
    return nil
}

func isLocal(_ node: some SyntaxProtocol) -> Bool {
    var ancestor = Syntax(node).parent
    while let parent = ancestor {
        if parent.is(CodeBlockSyntax.self) || parent.is(ClosureExprSyntax.self) { return true }
        ancestor = parent.parent
    }
    return false
}

private func isInstanceContext(_ node: some SyntaxProtocol) -> Bool {
    var ancestor = Syntax(node).parent
    while let parent = ancestor {
        if scopeName(parent) != nil { return true }
        let modifiers = parent.as(VariableDeclSyntax.self)?.modifiers ?? parent.as(FunctionDeclSyntax.self)?.modifiers
        if modifiers?.contains(where: { ["static", "class"].contains($0.name.text) }) == true { return false }
        ancestor = parent.parent
    }
    return false
}

private func qualified(_ scope: String, _ name: String) -> String {
    scope.isEmpty ? name : scope + "." + name
}

private func parentScope(_ scope: String) -> String {
    scope.split(separator: ".").dropLast().joined(separator: ".")
}

private func candidates(_ name: String, scope: String) -> [String] {
    if name == "Self" { return [scope] }
    if name.hasPrefix("Self.") || name.hasPrefix("self.") {
        return [qualified(scope, String(name.dropFirst(5)))]
    }
    var result: [String] = []
    var context = scope
    while !context.isEmpty {
        result.append(qualified(context, name))
        context = parentScope(context)
    }
    return result + [name]
}
