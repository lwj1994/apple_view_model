import Foundation
import SwiftSyntax

public enum ViewModelLintRule: String, CaseIterable, Codable, Hashable {
    case dependencyCycle = "dependency-cycle"
    case cachedViewModel = "cached-view-model"
    case aliveForeverKey = "alive-forever-key"
    case unmanagedConstruction = "unmanaged-construction"
}

public struct ViewModelLintConfiguration: Decodable {
    public let disabledRules: Set<ViewModelLintRule>

    public init(disabledRules: Set<ViewModelLintRule> = []) {
        self.disabledRules = disabledRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try container.decodeIfPresent(Set<String>.self, forKey: .disabledRules) ?? []
        disabledRules = try Set(names.filter { $0 != "parameterized-spec-key" }.map { name in
            guard let rule = ViewModelLintRule(rawValue: name) else {
                throw DecodingError.dataCorruptedError(forKey: .disabledRules, in: container,
                    debugDescription: "Unknown lint rule: \(name)")
            }
            return rule
        })
    }

    private enum CodingKeys: String, CodingKey { case disabledRules }
}

/// A single text replacement, in UTF-8 offsets of the scanned source.
public struct ViewModelLintEdit: Equatable {
    public let offset: Int
    public let length: Int
    public let replacement: String
}

public struct ViewModelLintWarning: Equatable {
    public let rule: ViewModelLintRule
    public let location: DependencyLocation
    public let message: String
    /// A safe mechanical fix, when one exists for this occurrence.
    public let fix: ViewModelLintEdit?

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

    /// Applies every safe fix and returns only the sources that changed.
    /// Overlapping edits keep the one that starts last; a rescan finds the rest.
    public static func fix(
        _ sources: [ScannerSource],
        configuration: ViewModelLintConfiguration = .init()
    ) -> [ScannerSource] {
        let warnings = scan(sources, configuration: configuration).warnings
        return sources.compactMap { source in
            let edits = warnings.filter { $0.location.path == source.path }
                .compactMap(\.fix).sorted { $0.offset > $1.offset }
            guard !edits.isEmpty else { return nil }
            var bytes = Array(source.text.utf8)
            var limit = Int.max
            for edit in edits where edit.offset + edit.length <= limit {
                bytes.replaceSubrange(edit.offset..<(edit.offset + edit.length), with: Array(edit.replacement.utf8))
                limit = edit.offset
            }
            return ScannerSource(path: source.path, text: String(decoding: bytes, as: UTF8.self))
        }
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
        if specName(node) != nil {
            checkSpec(node)
        } else {
            if let type = constructedViewModel(node), !isManagedBuilder(node) {
                warn(.unmanagedConstruction, at: node,
                     "Direct construction of \(type.name) outside a recognized spec builder or ViewModelFactory.build/buildThrowing; resolve a stable spec through a binding instead.")
            }
            if isResolution(node), let property = storedDestination(node) {
                warn(.cachedViewModel, at: node,
                     "Resolved ViewModel stored in '\(property)' can remain stale after recycle; use a computed property that calls watch/read(spec).",
                     fix: cachedFix(node))
            }
        }
        return .visitChildren
    }

    private func warn(_ rule: ViewModelLintRule, at node: some SyntaxProtocol, _ message: String,
                      fix: ViewModelLintEdit? = nil) {
        guard !configuration.disabledRules.contains(rule) else { return }
        warnings.append(ViewModelLintWarning(rule: rule, location: file.location(node), message: message, fix: fix))
    }

    /// `lazy var child = binding.read(spec)` becomes `var child: Child { binding.read(spec) }`.
    /// Needs a type from the annotation or the spec's explicit generic argument;
    /// throwing, async, observed and assigned storage is left for a person.
    private func cachedFix(_ call: FunctionCallExprSyntax) -> ViewModelLintEdit? {
        var value = Syntax(call)
        while let parent = value.parent, parent.is(ForceUnwrapExprSyntax.self) { value = parent }
        guard let initializer = value.parent?.as(InitializerClauseSyntax.self),
              let binding = initializer.parent?.as(PatternBindingSyntax.self),
              binding.accessorBlock == nil,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self),
              declaration.bindings.count == 1,
              let type = binding.typeAnnotation?.type.trimmedDescription ?? resolvedTypeText(call)
        else { return nil }
        // Keep attributes, access control and spacing; only `lazy` goes away.
        let start = declaration.positionAfterSkippingLeadingTrivia.utf8Offset
        var prefix = Array(declaration.description.utf8)[
            (start - declaration.position.utf8Offset)..<(declaration.bindingSpecifier.positionAfterSkippingLeadingTrivia.utf8Offset - declaration.position.utf8Offset)]
        if let lazy = declaration.modifiers.first(where: { $0.name.text == "lazy" }) {
            let from = lazy.positionAfterSkippingLeadingTrivia.utf8Offset - start
            let to = lazy.endPosition.utf8Offset - start
            prefix.removeSubrange((prefix.startIndex + from)..<(prefix.startIndex + to))
        }
        let text = String(decoding: prefix, as: UTF8.self) + "var \(name): \(type) { \(value.trimmedDescription) }"
        return replacing(declaration, with: text)
    }

    /// The explicit ViewModel type argument of the spec a resolution reads.
    private func resolvedTypeText(_ call: FunctionCallExprSyntax) -> String? {
        guard let argument = call.arguments.first?.expression else { return nil }
        if let inline = genericArgument(of: argument) { return inline }
        let reference = argument.as(FunctionCallExprSyntax.self)?.calledExpression ?? argument
        guard let name = expressionName(reference),
              name.contains(".") || localValue(named: name, at: call) == nil,
              let spec = index.resolveValue(name, scope: scope(of: call), file: file.path) else { return nil }
        if let type = spec.type.flatMap(genericArgument(of:)) { return type }
        return spec.initializer.flatMap(genericArgument(of:))
    }

    /// Adds a key named after the spec's variable before `aliveForever:`, or
    /// replaces a literal nil key. Argument specs get a key built from their arguments.
    private func keyFix(_ call: FunctionCallExprSyntax) -> ViewModelLintEdit? {
        guard let alive = call.arguments.first(where: { $0.label?.text == "aliveForever" }),
              let spec = specName(call) else { return nil }
        let bare = spec.hasPrefix("AppleViewModel.") ? String(spec.dropFirst(15)) : spec
        let suffix = bare.dropFirst("ViewModelSpecWithArg".count)
        let arity = bare == "ViewModelSpec" ? 0 : suffix.isEmpty ? 1 : Int(suffix)
        guard let arity else { return nil }
        let base = keyBase(call)
        let key = arity == 0
            ? "\"\(base)\""
            : "{ \"\(base)" + (0..<arity).map { "-\\($\($0))" }.joined() + "\" }"
        if let existing = call.arguments.first(where: { $0.label?.text == "key" }) {
            return replacing(existing.expression, with: key)
        }
        // Keep one argument per line when the call is laid out that way.
        let spacing = alive.leadingTrivia
        let separator = spacing.contains(where: \.isNewline) ? "," + spacing.description : ", "
        return ViewModelLintEdit(offset: alive.positionAfterSkippingLeadingTrivia.utf8Offset, length: 0,
                                 replacement: "key: \(key)\(separator)")
    }

    private func keyBase(_ call: FunctionCallExprSyntax) -> String {
        if let binding = call.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
           let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            let trimmed = name.hasSuffix("Spec") ? String(name.dropLast(4)) : name
            if !trimmed.isEmpty { return trimmed }
        }
        guard let type = genericArgument(of: ExprSyntax(call)), let first = type.first else { return "viewModel" }
        return first.lowercased() + type.dropFirst().prefix { $0.isLetter || $0.isNumber }
    }

    private func replacing(_ node: some SyntaxProtocol, with text: String) -> ViewModelLintEdit {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        return ViewModelLintEdit(offset: start, length: node.endPositionBeforeTrailingTrivia.utf8Offset - start,
                                 replacement: text)
    }

    private func checkSpec(_ node: FunctionCallExprSyntax) {
        let key = node.arguments.first { $0.label?.text == "key" }?.expression
            ?? node.additionalTrailingClosures.first { $0.label.text == "key" }.map { ExprSyntax($0.closure) }
        let missingKey = key == nil || key.flatMap(literalResult)?.is(NilLiteralExprSyntax.self) == true
        let alive = node.arguments.first { $0.label?.text == "aliveForever" }?.expression
            ?? node.additionalTrailingClosures.first { $0.label.text == "aliveForever" }.map { ExprSyntax($0.closure) }
        if missingKey, alive.flatMap(literalResult)?.as(BooleanLiteralExprSyntax.self)?.literal.text == "true" {
            warn(.aliveForeverKey, at: node,
                 "aliveForever is true without an explicit non-nil key; managed resolution requires a key.",
                 fix: keyFix(node))
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

/// The first generic argument of a spec type or spec construction, as written.
private func genericArgument(of node: some SyntaxProtocol) -> String? {
    if let type = node.as(TypeSyntax.self) {
        if let optional = type.as(OptionalTypeSyntax.self) { return genericArgument(of: optional.wrappedType) }
        let clause = type.as(IdentifierTypeSyntax.self)?.genericArgumentClause
            ?? type.as(MemberTypeSyntax.self)?.genericArgumentClause
        return clause?.arguments.first?.argument.trimmedDescription
    }
    guard let call = node.as(FunctionCallExprSyntax.self) else { return nil }
    var callee = call.calledExpression
    if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
       let base = member.base { callee = base }
    guard let name = expressionName(callee), isSpec(name) else { return nil }
    return callee.as(GenericSpecializationExprSyntax.self)?
        .genericArgumentClause.arguments.first?.argument.trimmedDescription
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
        if let statements = localStatements(in: node) {
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
