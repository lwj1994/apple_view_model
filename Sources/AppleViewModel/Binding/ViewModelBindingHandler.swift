import Foundation

/// Source-aware owner registry attached to every managed ViewModel generation.
@MainActor
public final class ViewModelBindingHandler {
    private struct OwnerEntry {
        let binding: ViewModelBinding
        let order: Int
        var sources: Set<ObjectIdentifier>
    }

    private struct OwnerListenerEntry {
        let id: UUID
        let callback: ([String], String?, String?) throws -> Void
    }

    private var refSources: [ObjectIdentifier: OwnerEntry] = [:]
    private var nextOwnerOrder = 0
    private var ownerRevision = 0
    private var ownerChangeListeners: [OwnerListenerEntry] = []

    public init() {}

    @_spi(Internal)
    public var owners: [ViewModelBinding] {
        // Swift dictionaries do not preserve insertion order. Keep that order
        // in the source ledger instead of maintaining a second owner list.
        refSources.values.sorted { $0.order < $1.order }.map(\.binding)
    }

    @_spi(Internal)
    public var externalOwners: [ViewModelBinding] {
        owners.filter { !$0.isDependencyBinding }
    }

    @_spi(Internal)
    public var constructionExternalOwners: [ViewModelBinding] {
        let current = externalOwners
        if !current.isEmpty { return current }
        guard
            let building = ViewModelBinding.currentBuilding,
            !building.isDisposed,
            !building.isDependencyBinding
        else { return [] }
        return [building]
    }

    @_spi(Internal)
    public var primaryOwner: ViewModelBinding? {
        refSources.values.min { $0.order < $1.order }?.binding
    }

    /// Whether this binding has its own reference, independently of parents.
    func hasDirectRef(_ binding: ViewModelBinding) -> Bool {
        let identity = ObjectIdentifier(binding)
        return refSources[identity]?.sources.contains(identity) == true
    }

    @_spi(Internal)
    @discardableResult
    public func addOwnerChangeListener(
        _ listener: @escaping ([String], String?, String?) throws -> Void
    ) -> () -> Void {
        let id = UUID()
        ownerChangeListeners.append(OwnerListenerEntry(id: id, callback: listener))
        return { [weak self] in
            self?.ownerChangeListeners.removeAll { $0.id == id }
        }
    }

    @_spi(Internal)
    public func addRef(_ binding: ViewModelBinding, source: AnyObject? = nil) {
        commitAddRef(binding, source: source)?()
    }

    /// Commit without calling user code. The handle publishes only after both
    /// ownership ledgers agree.
    func commitAddRef(_ binding: ViewModelBinding, source: AnyObject? = nil) -> (() -> Void)? {
        let previousPrimaryOwner = primaryOwner?.id
        let bindingIdentity = ObjectIdentifier(binding)
        let sourceIdentity = ObjectIdentifier(source ?? binding)
        var entry: OwnerEntry
        if let existing = refSources[bindingIdentity] {
            entry = existing
        } else {
            entry = OwnerEntry(binding: binding, order: nextOwnerOrder, sources: [])
            nextOwnerOrder += 1
        }
        guard entry.sources.insert(sourceIdentity).inserted else { return nil }
        let isFirstSource = entry.sources.count == 1
        refSources[bindingIdentity] = entry
        return isFirstSource ? ownerChange(previousPrimaryOwner: previousPrimaryOwner) : nil
    }

    @_spi(Internal)
    public func removeRef(_ binding: ViewModelBinding, source: AnyObject? = nil) {
        commitRemoveRef(binding, source: source)?()
    }

    func commitRemoveRef(_ binding: ViewModelBinding, source: AnyObject? = nil) -> (() -> Void)? {
        let previousPrimaryOwner = primaryOwner?.id
        let bindingIdentity = ObjectIdentifier(binding)
        let sourceIdentity = ObjectIdentifier(source ?? binding)
        guard var entry = refSources[bindingIdentity] else { return nil }
        guard entry.sources.remove(sourceIdentity) != nil else { return nil }
        if !entry.sources.isEmpty {
            refSources[bindingIdentity] = entry
            return nil
        }
        refSources.removeValue(forKey: bindingIdentity)
        return ownerChange(previousPrimaryOwner: previousPrimaryOwner)
    }

    func commitClearRefs() -> (() -> Void)? {
        guard !refSources.isEmpty else { return nil }
        let previousPrimaryOwner = primaryOwner?.id
        refSources.removeAll()
        return ownerChange(previousPrimaryOwner: previousPrimaryOwner)
    }

    private func ownerChange(previousPrimaryOwner: String?) -> () -> Void {
        ownerRevision += 1
        let revision = ownerRevision
        return { [weak self] in
            guard let self, revision == self.ownerRevision else { return }
            self.notifyOwnerChanges(previousPrimaryOwner: previousPrimaryOwner, revision: revision)
        }
    }

    @_spi(Internal)
    public func dispose() {
        commitClearRefs()?()
        ownerChangeListeners.removeAll()
    }

    @_spi(Internal)
    public var binding: ViewModelBinding {
        if let first = primaryOwner { return first }
        if let current = ViewModelBinding.currentBuilding { return current }
        preconditionFailure(
            "No binding available. ViewModel must be used within a ViewModelBinding context."
        )
    }

    private func notifyOwnerChanges(previousPrimaryOwner: String?, revision: Int) {
        guard !ownerChangeListeners.isEmpty else { return }
        let ownerIds = owners.map(\.id)
        let currentPrimaryOwner = primaryOwner?.id
        let snapshot = ownerChangeListeners
        for entry in snapshot {
            // A callback may commit and publish a newer transition. Stop the
            // stale fan-out rather than deliver its obsolete owner snapshot.
            guard revision == ownerRevision else { break }
            guard ownerChangeListeners.contains(where: { $0.id == entry.id }) else {
                continue
            }
            do {
                try entry.callback(ownerIds, previousPrimaryOwner, currentPrimaryOwner)
            } catch {
                reportViewModelError(
                    error,
                    type: .listener,
                    context: "ViewModel owner diagnostics listener error"
                )
            }
        }
    }
}
