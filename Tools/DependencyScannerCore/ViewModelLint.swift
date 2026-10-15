import Foundation
import SwiftSyntax

public enum ViewModelLintRule: String, CaseIterable, Codable, Hashable {
    case dependencyCycle = "dependency-cycle"
    case cachedViewModel = "cached-view-model"
    case aliveForeverKey = "alive-forever-key"
    case unmanagedConstruction = "unmanaged-construction"
    case parameterizedSpecKey = "parameterized-spec-key"
}

public struct ViewModelLintConfiguration: Decodable {
    public let disabledRules: Set<ViewModelLintRule>

    public init(disabledRules: Set<ViewModelLintRule> = []) {
        self.disabledRules = disabledRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disabledRules = try container.decodeIfPresent(Set<ViewModelLintRule>.self, forKey: .disabledRules) ?? []
    }

    private enum CodingKeys: String, CodingKey { case disabledRules }
}

public struct ViewModelLintWarning: Equatable {
    public let rule: ViewModelLintRule
    public let location: DependencyLocation
    public let message: String

    public var diagnostic: String {
        "\(location.diagnosticPrefix): warning: AppleViewModel [\(rule.rawValue)]: \(message)"
    }
}

public struct ViewModelLintReport {
    public let cycles: [DependencyCycle]
    public let warnings: [ViewModelLintWarning]
}

public enum ViewModelLint {
    public static func scan(
        _ sources: [ScannerSource],
        configuration: ViewModelLintConfiguration = .init()
    ) -> ViewModelLintReport {
        let files = sources.sorted { $0.path < $1.path }.map(ParsedFile.init)
        let index = DeclarationIndex(files: files)
        let cycles = configuration.disabledRules.contains(.dependencyCycle)
            ? [] : DependencyScanner.scan(files: files, index: index)
        let warnings = files.flatMap { file in
            let visitor = UsageVisitor(file: file, index: index, configuration: configuration)
            visitor.walk(file.tree)
            return visitor.warnings
        }
        return ViewModelLintReport(cycles: cycles, warnings: warnings)
    }
}

private final class UsageVisitor: SyntaxVisitor {
    let file: ParsedFile
    let index: DeclarationIndex
    let configuration: ViewModelLintConfiguration
    var warnings: [ViewModelLintWarning] = []

    init(file: ParsedFile, index: DeclarationIndex, configuration: ViewModelLintConfiguration) {
        self.file = file
        self.index = index
        self.configuration = configuration
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        isLocal(node) ? .skipChildren : .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = specName(node) {
            checkSpec(node, name: name)
        } else {
            if let type = constructedViewModel(node), !isManagedBuilder(node) {
                warn(.unmanagedConstruction, at: node,
                     "Direct construction of \(type.name) outside a recognized spec builder or ViewModelFactory.build/buildThrowing; resolve a stable spec through a binding instead.")
            }
            if isResolution(node), let property = storedDestination(node) {
                warn(.cachedViewModel, at: node,
                     "Resolved ViewModel stored in '\(property)' can remain stale after recycle; use a computed property that calls watch/read(spec).")
            }
        }
        return .visitChildren
    }

    private func warn(_ rule: ViewModelLintRule, at node: some SyntaxProtocol, _ message: String) {
        guard !configuration.disabledRules.contains(rule) else { return }
        warnings.append(ViewModelLintWarning(rule: rule, location: file.location(node), message: message))
    }

    private func checkSpec(_ node: FunctionCallExprSyntax, name: String) {
        let key = node.arguments.first { $0.label?.text == "key" }?.expression
            ?? node.additionalTrailingClosures.first { $0.label.text == "key" }.map { ExprSyntax($0.closure) }
        let missingKey = key == nil || key.flatMap(literalResult)?.is(NilLiteralExprSyntax.self) == true
        let alive = node.arguments.first { $0.label?.text == "aliveForever" }?.expression
            ?? node.additionalTrailingClosures.first { $0.label.text == "aliveForever" }.map { ExprSyntax($0.closure) }
        if missingKey, alive.flatMap(literalResult)?.as(BooleanLiteralExprSyntax.self)?.literal.text == "true" {
            warn(.aliveForeverKey, at: node,
                 "aliveForever is true without an explicit non-nil key; managed resolution requires a key.")
        }
        if missingKey, name.split(separator: ".").last != "ViewModelSpec" {
            warn(.parameterizedSpecKey, at: node,
                 "Parameterized spec has no explicit key; different arguments can reuse the same ViewModel within one binding. Add an argument-derived key if separate instances are intended.")
        }
    }

    private func specName(_ call: FunctionCallExprSyntax) -> String? {
        guard let name = constructorName(call), isSpec(name) else { return nil }
        // A locally declared type with the same name is not the framework spec.
        guard index.resolveType(name, scope: scope(of: call), file: file.path) == nil else { return nil }
        return name
    }

    private func constructorName(_ call: FunctionCallExprSyntax) -> String? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init" {
            if let base = member.base {
                guard let name = expressionName(base), name != "self", name != "super" else { return nil }
                return name
            }
            // Contextual .init is supported for a directly annotated declaration.
            if let initializer = call.parent?.as(InitializerClauseSyntax.self),
               let binding = initializer.parent?.as(PatternBindingSyntax.self) {
                return binding.typeAnnotation.flatMap { nominalTypeName($0.type) }
            }
            return nil
        }
        return expressionName(call.calledExpression)
    }

    private func constructedViewModel(_ call: FunctionCallExprSyntax) -> TypeDeclaration? {
        guard let name = constructorName(call) else { return nil }
        if !name.contains("."), localValue(named: name, at: call) != nil { return nil }
        guard let type = index.resolveType(name, scope: scope(of: call), file: file.path),
              index.viewModels.contains(type.id) else { return nil }
        return type
    }

    private func isManagedBuilder(_ call: FunctionCallExprSyntax) -> Bool {
        var ancestor = call.parent
        while let node = ancestor {
            if let closure = node.as(ClosureExprSyntax.self) {
                // Only the builder closure is exempt, never a key/tag closure.
                if let specCall = closure.parent?.as(FunctionCallExprSyntax.self),
                   specName(specCall) != nil,
                   !specCall.arguments.contains(where: { ["builder", "throwingBuilder"].contains($0.label?.text) }) {
                    return true
                }
                if let argument = closure.parent?.as(LabeledExprSyntax.self),
                   ["builder", "throwingBuilder"].contains(argument.label?.text),
                   let specCall = argument.parent?.parent?.as(FunctionCallExprSyntax.self), specName(specCall) != nil {
                    return true
                }
            }
            if let function = node.as(FunctionDeclSyntax.self),
               !isLocal(function),
               ["build", "buildThrowing"].contains(function.name.text),
               function.signature.parameterClause.parameters.isEmpty,
               !function.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) {
                if let owner = index.resolveType(scope(of: function), scope: "", file: file.path),
                   index.factories.contains(owner.id) { return true }
                // Conformance can also be declared on an extension in this target.
                var parent = function.parent
                while let context = parent {
                    if let ext = context.as(ExtensionDeclSyntax.self) {
                        return ext.inheritanceClause?.inheritedTypes.contains {
                            ["ViewModelFactory", "AppleViewModel.ViewModelFactory"].contains(typeName($0.type))
                        } == true
                    }
                    if scopeName(context) != nil { break }
                    parent = context.parent
                }
            }
            // Do not exempt a nested type's methods merely because its declaration
            // happens to be inside a builder closure.
            if scopeName(node) != nil { return false }
            ancestor = node.parent
        }
        return false
    }

    private func isResolution(_ call: FunctionCallExprSyntax) -> Bool {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              ["read", "watch", "readThrowing", "watchThrowing"].contains(member.declName.baseName.text),
              let receiver = member.base.flatMap(expressionName) else { return false }
        if !receiver.contains("."), let local = localValue(named: receiver, at: call) {
            return isBinding(local)
        }
        if ["viewModelBinding", "self.viewModelBinding"].contains(receiver) { return true }
        guard let value = index.resolveValue(receiver, scope: scope(of: call), file: file.path) else { return false }
        return isBinding(LocalValue(type: value.type, initializer: value.initializer))
    }

    private func storedDestination(_ call: FunctionCallExprSyntax) -> String? {
        var child = Syntax(call)
        while let parent = child.parent {
            if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
                child = parent
                continue
            }
            if let initializer = parent.as(InitializerClauseSyntax.self),
               let binding = initializer.parent?.as(PatternBindingSyntax.self),
               !isLocal(binding), isStoredProperty(binding) {
                return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            }
            if parent.is(ExprListSyntax.self), let sequence = parent.parent?.as(SequenceExprSyntax.self) {
                let elements = Array(sequence.elements)
                guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
                      elements[2].id == child.id,
                      let name = expressionName(elements[0]) else { return nil }
                if !name.contains("."), localValue(named: name, at: call) != nil { return nil }
                guard let value = index.resolveValue(name, scope: scope(of: call), file: file.path),
                      value.isStored else { return nil }
                return name
            }
            // Local temporaries, computed getters, closures and transformed
            // results such as title(read(spec)) are not direct storage of a VM.
            break
        }
        return nil
    }
}

func isStoredProperty(_ binding: PatternBindingSyntax) -> Bool {
    guard let block = binding.accessorBlock else { return true }
    guard case .accessors(let accessors) = block.accessors else { return false }
    return accessors.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
}

private func nominalTypeName(_ type: TypeSyntax) -> String? {
    if let optional = type.as(OptionalTypeSyntax.self) { return nominalTypeName(optional.wrappedType) }
    if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return nominalTypeName(optional.wrappedType) }
    return typeName(type)
}

private func literalResult(_ expression: ExprSyntax) -> ExprSyntax? {
    if let closure = expression.as(ClosureExprSyntax.self) {
        guard closure.statements.count == 1, let item = closure.statements.first else { return nil }
        return item.item.as(ExprSyntax.self) ?? item.item.as(ReturnStmtSyntax.self)?.expression
    }
    return expression
}

private struct LocalValue {
    let type: TypeSyntax?
    let initializer: ExprSyntax?
}

private func isBinding(_ value: LocalValue) -> Bool {
    let name = value.type.flatMap(nominalTypeName)
        ?? value.initializer?.as(FunctionCallExprSyntax.self).flatMap { expressionName($0.calledExpression) }
    return ["ViewModelBinding", "HostedViewModelBinding", "AppleViewModel.ViewModelBinding", "AppleViewModel.HostedViewModelBinding"]
        .contains(name)
}

private func localValue(named name: String, at call: FunctionCallExprSyntax) -> LocalValue? {
    var ancestor = call.parent
    while let node = ancestor {
        let statements = node.as(CodeBlockSyntax.self)?.statements
            ?? node.as(ClosureExprSyntax.self)?.statements
        if let statements {
            for item in statements.reversed() where item.position < call.position {
                guard let declaration = item.item.as(VariableDeclSyntax.self) else { continue }
                for binding in declaration.bindings where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                    return LocalValue(type: binding.typeAnnotation?.type, initializer: binding.initializer?.value)
                }
            }
        }
        let parameters = node.as(FunctionDeclSyntax.self)?.signature.parameterClause.parameters
            ?? node.as(InitializerDeclSyntax.self)?.signature.parameterClause.parameters
        if let parameter = parameters?.first(where: { ($0.secondName ?? $0.firstName).text == name }) {
            return LocalValue(type: parameter.type, initializer: nil)
        }
        if let clause = node.as(ClosureExprSyntax.self)?.signature?.parameterClause {
            if let parameters = clause.as(ClosureShorthandParameterListSyntax.self),
               parameters.contains(where: { $0.name.text == name }) { return LocalValue(type: nil, initializer: nil) }
            if let parameters = clause.as(ClosureParameterClauseSyntax.self),
               let parameter = parameters.parameters.first(where: { ($0.secondName ?? $0.firstName).text == name }) {
                return LocalValue(type: parameter.type, initializer: nil)
            }
        }
        if scopeName(node) != nil { break }
        ancestor = node.parent
    }
    return nil
}
