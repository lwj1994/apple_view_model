import Foundation

/// Source-aware owner registry attached to every managed ViewModel generation.
@MainActor
public final class ViewModelBindingHandler {
    private struct OwnerEntry {
        let binding: ViewModelBinding
        let order: Int
        var sources: Set<ObjectIdentifier>
    }

    /// A diagnostics listener receives the full owner snapshot; a dependency
    /// binding receives only the owner that changed, because a shared ViewModel
    /// can be owned by thousands of list cells.
    private enum OwnerListener {
        case snapshot(([String], String?, String?) throws -> Void)
        case delta((Int, ViewModelBinding?, Bool) -> Void)
    }

    private struct OwnerListenerEntry {
        let id: UUID
        let listener: OwnerListener
    }

    private var refSources: [ObjectIdentifier: OwnerEntry] = [:]
    private var nextOwnerOrder = 0
    private var ownerRevision = 0
    private var ownerChangeListeners: [OwnerListenerEntry] = []
    private var snapshotListenerCount = 0

    /// Primary owner id for diagnostics listeners only. Finding it scans every
    /// owner, so it is not computed per change when nobody reads it.
    private var primaryOwnerForDiagnostics: String? {
        snapshotListenerCount == 0 ? nil : primaryOwner?.id
    }

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
        addListener(.snapshot(listener))
    }

    /// Adds an incremental owner listener for dependency bindings.
    ///
    /// The callback receives this handler's ownership revision for the change,
    /// the single binding that was added (`added == true`) or removed, or nil
    /// when several owners changed at once. A listener that has seen every
    /// previous revision can apply the change directly; otherwise it must
    /// resynchronize from `externalOwners`.
    @discardableResult
    func addOwnerDeltaListener(
        _ listener: @escaping (_ revision: Int, _ owner: ViewModelBinding?, _ added: Bool) -> Void
    ) -> () -> Void {
        addListener(.delta(listener))
    }

    private func addListener(_ listener: OwnerListener) -> () -> Void {
        let id = UUID()
        ownerChangeListeners.append(OwnerListenerEntry(id: id, listener: listener))
        if case .snapshot = listener { snapshotListenerCount += 1 }
        return { [weak self] in
            guard let self,
                  let index = self.ownerChangeListeners.firstIndex(where: { $0.id == id })
            else { return }
            self.ownerChangeListeners.remove(at: index)
            if case .snapshot = listener { self.snapshotListenerCount -= 1 }
        }
    }

    @_spi(Internal)
    public func addRef(_ binding: ViewModelBinding, source: AnyObject? = nil) {
        commitAddRef(binding, source: source)?()
    }

    /// Commit without calling user code. The handle publishes only after both
    /// ownership ledgers agree.
    func commitAddRef(_ binding: ViewModelBinding, source: AnyObject? = nil) -> (() -> Void)? {
        let previousPrimaryOwner = primaryOwnerForDiagnostics
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
        return isFirstSource
            ? ownerChange(previousPrimaryOwner: previousPrimaryOwner, owner: binding, added: true)
            : nil
    }

    @_spi(Internal)
    public func removeRef(_ binding: ViewModelBinding, source: AnyObject? = nil) {
        commitRemoveRef(binding, source: source)?()
    }

    func commitRemoveRef(_ binding: ViewModelBinding, source: AnyObject? = nil) -> (() -> Void)? {
        let previousPrimaryOwner = primaryOwnerForDiagnostics
        let bindingIdentity = ObjectIdentifier(binding)
        let sourceIdentity = ObjectIdentifier(source ?? binding)
        guard var entry = refSources[bindingIdentity] else { return nil }
        guard entry.sources.remove(sourceIdentity) != nil else { return nil }
        if !entry.sources.isEmpty {
            refSources[bindingIdentity] = entry
            return nil
        }
        refSources.removeValue(forKey: bindingIdentity)
        return ownerChange(previousPrimaryOwner: previousPrimaryOwner, owner: binding, added: false)
    }

    func commitClearRefs() -> (() -> Void)? {
        guard !refSources.isEmpty else { return nil }
        let previousPrimaryOwner = primaryOwnerForDiagnostics
        refSources.removeAll()
        return ownerChange(previousPrimaryOwner: previousPrimaryOwner, owner: nil, added: false)
    }

    private func ownerChange(
        previousPrimaryOwner: String?,
        owner: ViewModelBinding?,
        added: Bool
    ) -> () -> Void {
        ownerRevision += 1
        let revision = ownerRevision
        return { [weak self] in
            guard let self, revision == self.ownerRevision else { return }
            self.notifyOwnerChanges(
                previousPrimaryOwner: previousPrimaryOwner,
                revision: revision,
                owner: owner,
                added: added
            )
        }
    }

    @_spi(Internal)
    public func dispose() {
        commitClearRefs()?()
        ownerChangeListeners.removeAll()
        snapshotListenerCount = 0
    }

    @_spi(Internal)
    public var binding: ViewModelBinding {
        if let first = primaryOwner { return first }
        if let current = ViewModelBinding.currentBuilding { return current }
        preconditionFailure(
            "No binding available. ViewModel must be used within a ViewModelBinding context."
        )
    }

    private func notifyOwnerChanges(
        previousPrimaryOwner: String?,
        revision: Int,
        owner: ViewModelBinding?,
        added: Bool
    ) {
        guard !ownerChangeListeners.isEmpty else { return }
        // Built only for diagnostics listeners: sorting the owners per change
        // would make every owner change O(owners log owners).
        var ownerIds: [String]?
        let currentPrimaryOwner = primaryOwnerForDiagnostics
        let snapshot = ownerChangeListeners
        for entry in snapshot {
            // A callback may commit and publish a newer transition. Stop the
            // stale fan-out rather than deliver its obsolete owner snapshot.
            guard revision == ownerRevision else { break }
            guard ownerChangeListeners.contains(where: { $0.id == entry.id }) else {
                continue
            }
            do {
                switch entry.listener {
                case .delta(let callback):
                    callback(revision, owner, added)
                case .snapshot(let callback):
                    let ids = ownerIds ?? owners.map(\.id)
                    ownerIds = ids
                    try callback(ids, previousPrimaryOwner, currentPrimaryOwner)
                }
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
