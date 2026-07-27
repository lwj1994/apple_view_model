import Foundation

/// Identity-only key used as the stable default for one binding scope.
final class ViewModelPrivateKey: Hashable, @unchecked Sendable {
    static func == (lhs: ViewModelPrivateKey, rhs: ViewModelPrivateKey) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

@MainActor
private struct ConstructionIdentity {
    let type: ObjectIdentifier
    let typeName: String
    let key: AnyHashable
    let isImplicit: Bool

    var description: String {
        isImplicit ? "\(typeName)(unkeyed)" : "\(typeName)(\(key))"
    }
}

@MainActor
private final class ConstructionTransaction {
    private var rollbacks: [() -> Void] = []
    private var completed = false

    func register(_ rollback: @escaping () -> Void) {
        guard !completed else { return }
        rollbacks.append(rollback)
    }

    func commit() {
        guard !completed else { return }
        completed = true
        rollbacks.removeAll()
    }

    func rollback() {
        guard !completed else { return }
        completed = true
        for callback in rollbacks.reversed() {
            callback()
        }
        rollbacks.removeAll()
    }
}

@MainActor private var activeConstructionLineage: [ConstructionIdentity] = []
@MainActor private var activeConstructionTransaction: ConstructionTransaction?

@MainActor
func registerViewModelConstructionRollback(_ rollback: @escaping () -> Void) {
    activeConstructionTransaction?.register(rollback)
}

@MainActor
func runInViewModelConstruction<R, Value: AnyObject>(
    _ type: Value.Type,
    key: AnyHashable,
    isImplicit: Bool,
    body: () throws -> R
) throws -> R {
    let typeId = ObjectIdentifier(type)
    let cycle = activeConstructionLineage.contains { ancestor in
        guard ancestor.type == typeId else { return false }
        if isImplicit { return true }
        return !ancestor.isImplicit && ancestor.key == key
    }
    let current = ConstructionIdentity(
        type: typeId,
        typeName: String(describing: type),
        key: key,
        isImplicit: isImplicit
    )
    if cycle {
        let path = (activeConstructionLineage + [current])
            .map(\.description)
            .joined(separator: " -> ")
        throw ViewModelError(
            "Circular ViewModel construction detected: \(path). "
                + "Unkeyed ViewModels are compared by type within the current construction lineage."
        )
    }

    let transaction = ConstructionTransaction()
    let previous = activeConstructionTransaction
    activeConstructionTransaction = transaction
    activeConstructionLineage.append(current)
    defer {
        activeConstructionLineage.removeLast()
        activeConstructionTransaction = previous
    }
    do {
        let result = try body()
        transaction.commit()
        return result
    } catch {
        transaction.rollback()
        throw error
    }
}

@MainActor
private final class ViewModelUpdateTransaction {
    var updatedBindings: Set<ObjectIdentifier> = []
}

@MainActor private var activeUpdateTransaction: ViewModelUpdateTransaction?

@MainActor
func runInViewModelUpdateTransaction<R>(_ body: () -> R) -> R {
    if activeUpdateTransaction != nil { return body() }
    activeUpdateTransaction = ViewModelUpdateTransaction()
    defer { activeUpdateTransaction = nil }
    return body()
}

@MainActor
func markViewModelBindingUpdated(_ binding: ViewModelBinding) -> Bool {
    guard let transaction = activeUpdateTransaction else { return true }
    return transaction.updatedBindings.insert(ObjectIdentifier(binding)).inserted
}
