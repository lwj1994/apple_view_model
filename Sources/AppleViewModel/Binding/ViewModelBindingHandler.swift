import Foundation

/// Source-aware owner registry attached to every managed ViewModel generation.
@MainActor
public final class ViewModelBindingHandler {
    private struct OwnerEntry {
        let binding: ViewModelBinding
        var sources: Set<ObjectIdentifier>
    }

    private struct OwnerListenerEntry {
        let id: UUID
        let callback: ([String], String?, String?) throws -> Void
    }

    private var dependencyBindings: [ViewModelBinding] = []
    private var refSources: [ObjectIdentifier: OwnerEntry] = [:]
    private var ownerChangeListeners: [OwnerListenerEntry] = []

    public init() {}

    @_spi(Internal)
    public var owners: [ViewModelBinding] { dependencyBindings }

    @_spi(Internal)
    public var externalOwners: [ViewModelBinding] {
        dependencyBindings.filter { !$0.isDependencyBinding }
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
    public var primaryOwner: ViewModelBinding? { dependencyBindings.first }

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
        let previousPrimaryOwner = primaryOwner?.id
        let bindingIdentity = ObjectIdentifier(binding)
        let sourceIdentity = ObjectIdentifier(source ?? binding)
        var entry = refSources[bindingIdentity]
            ?? OwnerEntry(binding: binding, sources: [])
        guard entry.sources.insert(sourceIdentity).inserted else { return }
        let isFirstSource = entry.sources.count == 1
        refSources[bindingIdentity] = entry
        if isFirstSource {
            dependencyBindings.append(binding)
            notifyOwnerChanges(previousPrimaryOwner: previousPrimaryOwner)
        }
    }

    @_spi(Internal)
    public func removeRef(_ binding: ViewModelBinding, source: AnyObject? = nil) {
        let previousPrimaryOwner = primaryOwner?.id
        let bindingIdentity = ObjectIdentifier(binding)
        let sourceIdentity = ObjectIdentifier(source ?? binding)
        guard var entry = refSources[bindingIdentity] else { return }
        guard entry.sources.remove(sourceIdentity) != nil else { return }
        if !entry.sources.isEmpty {
            refSources[bindingIdentity] = entry
            return
        }
        refSources.removeValue(forKey: bindingIdentity)
        dependencyBindings.removeAll { $0 === binding }
        notifyOwnerChanges(previousPrimaryOwner: previousPrimaryOwner)
    }

    @_spi(Internal)
    public func dispose() {
        let previousPrimaryOwner = primaryOwner?.id
        dependencyBindings.removeAll()
        refSources.removeAll()
        notifyOwnerChanges(previousPrimaryOwner: previousPrimaryOwner)
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

    private func notifyOwnerChanges(previousPrimaryOwner: String?) {
        guard !ownerChangeListeners.isEmpty else { return }
        let ownerIds = dependencyBindings.map(\.id)
        let currentPrimaryOwner = primaryOwner?.id
        let snapshot = ownerChangeListeners
        for entry in snapshot {
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
