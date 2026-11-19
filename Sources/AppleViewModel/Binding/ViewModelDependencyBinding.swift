import Foundation

/// Stable dependency and lifecycle scope owned by one parent object generation.
@MainActor
final class ViewModelDependencyBinding: ViewModelBinding {
    // Each attachment owns a distinct token, including reattachment of the same handle.
    private final class DependencyEntry {
        let handle: any _AnyHandle
        let viewModel: ViewModel

        init(handle: any _AnyHandle, viewModel: ViewModel) {
            self.handle = handle
            self.viewModel = viewModel
        }
    }

    private struct PropagatedOwner {
        let binding: ViewModelBinding
        let order: Int
    }

    private weak var parent: ViewModel?
    /// Root owners mirrored onto every dependency. Keyed by identity so
    /// membership checks and removals stay O(1): a shared ViewModel can be owned
    /// by thousands of list cells. `order` keeps the parent's owner order.
    private var propagatedOwners: [ObjectIdentifier: PropagatedOwner] = [:]
    private var nextPropagationOrder = 0
    /// Parent owner revision `propagatedOwners` reflects; nil until the first
    /// change, because construction may have used the building binding.
    private var syncedRevision: Int?
    private var dependencies: [ObjectIdentifier: DependencyEntry] = [:]
    private var removeOwnerListener: (() -> Void)?
    private var dependencyDisposed = false

    override var isDependencyBinding: Bool { true }

    init(
        parent: ViewModel,
        parentHandler: ViewModelBindingHandler
    ) {
        self.parent = parent
        super.init()

        for owner in parentHandler.constructionExternalOwners { insertPropagated(owner) }
        installDependencyHooks(
            attaching: { [weak self] _, viewModel in
                try self?.requireAcyclicDependency(viewModel)
            },
            attached: { [weak self] handle, viewModel in
                self?.handleAttached(handle, viewModel: viewModel)
            },
            detached: { [weak self] handle, _ in
                self?.handleDetached(handle)
            },
            updated: { [weak self] _ in
                self?.onUpdate()
            }
        )
        registerViewModelConstructionRollback { [weak self] in self?.dispose() }
        removeOwnerListener = parentHandler.addOwnerDeltaListener {
            [weak self, weak parentHandler] revision, owner, added in
            guard let self, let parentHandler else { return }
            self.ownersChanged(parentHandler, revision: revision, owner: owner, added: added)
        }
    }

    public override func onUpdate() {
        guard
            !dependencyDisposed,
            !InstanceManager.shared.isResetting,
            let parent,
            !parent.isDisposed
        else { return }
        // This is notification forwarding, not a business callback. Bindings
        // watching the parent request a refresh; read-only owners stay silent.
        parent.notifyListeners()
    }

    public override func dispose() {
        guard !dependencyDisposed else { return }
        dependencyDisposed = true
        removeOwnerListener?()
        removeOwnerListener = nil
        // The base marks this binding disposed before releasing any owners.
        // Its controller releases each edge together with propagated sources.
        super.dispose()
        propagatedOwners.removeAll()
        dependencies.removeAll()
    }

    private func handleAttached(
        _ handle: any _AnyHandle,
        viewModel: ViewModel
    ) -> (() -> Void)? {
        let entry = DependencyEntry(handle: handle, viewModel: viewModel)
        dependencies[ObjectIdentifier(handle)] = entry
        return { [weak self] in
            guard let self else { return }
            for owner in self.orderedPropagatedOwners {
                self.attachOwner(entry, owner: owner)
            }
        }
    }

    private func handleDetached(_ handle: any _AnyHandle) -> (() -> Void)? {
        guard let entry = dependencies.removeValue(forKey: ObjectIdentifier(handle)) else { return nil }
        let owners = orderedPropagatedOwners
        return { [weak self] in
            guard let self else { return }
            for owner in owners {
                self.detachOwner(entry, owner: owner)
            }
            // Explicit unbind releases ownership without requesting a refresh.
        }
    }

    private func requireAcyclicDependency(_ dependency: ViewModel) throws {
        guard let parent else { return }
        let createsCycle = dependency === parent
            || dependency.dependencyBindingIfCreated?.reaches(
                parent,
                visited: []
            ) == true
        if createsCycle {
            throw ViewModelError(
                "Circular ViewModel dependency detected: "
                    + "\(type(of: parent)) -> \(type(of: dependency))."
            )
        }
    }

    private func reaches(
        _ target: ViewModel,
        visited: Set<ObjectIdentifier>
    ) -> Bool {
        let identity = ObjectIdentifier(self)
        guard !visited.contains(identity) else { return false }
        var nextVisited = visited
        nextVisited.insert(identity)
        for entry in dependencies.values {
            if entry.viewModel === target { return true }
            if entry.viewModel.dependencyBindingIfCreated?.reaches(
                target,
                visited: nextVisited
            ) == true {
                return true
            }
        }
        return false
    }

    private var orderedPropagatedOwners: [ViewModelBinding] {
        propagatedOwners.values.sorted { $0.order < $1.order }.map(\.binding)
    }

    private func isPropagated(_ owner: ViewModelBinding) -> Bool {
        propagatedOwners[ObjectIdentifier(owner)] != nil
    }

    @discardableResult
    private func insertPropagated(_ owner: ViewModelBinding) -> Bool {
        let identity = ObjectIdentifier(owner)
        guard propagatedOwners[identity] == nil else { return false }
        propagatedOwners[identity] = PropagatedOwner(binding: owner, order: nextPropagationOrder)
        nextPropagationOrder += 1
        return true
    }

    private func ownersChanged(
        _ parentHandler: ViewModelBindingHandler,
        revision: Int,
        owner: ViewModelBinding?,
        added: Bool
    ) {
        guard !dependencyDisposed else { return }
        let inStep = syncedRevision == revision - 1
        // Record the revision before child callbacks can reenter with a newer one.
        syncedRevision = revision
        // A clear, or a change skipped by reentrancy, needs the full owner list.
        guard let owner, inStep else {
            syncOwners(parentHandler.externalOwners)
            return
        }
        guard !owner.isDependencyBinding else { return }
        if added {
            if insertPropagated(owner) { attachToDependencies(owner) }
        } else if propagatedOwners.removeValue(forKey: ObjectIdentifier(owner)) != nil {
            detachFromDependencies(owner)
        }
    }

    private func syncOwners(_ currentOwners: [ViewModelBinding]) {
        let current = Set(currentOwners.map(ObjectIdentifier.init))
        let removed = orderedPropagatedOwners.filter { !current.contains(ObjectIdentifier($0)) }
        let added = currentOwners.filter { !isPropagated($0) }

        // Commit this projection before child callbacks can reenter sync.
        propagatedOwners.removeAll(keepingCapacity: true)
        for owner in currentOwners { insertPropagated(owner) }
        for owner in removed { detachFromDependencies(owner) }
        for owner in added { attachToDependencies(owner) }
    }

    private func attachToDependencies(_ owner: ViewModelBinding) {
        for entry in Array(dependencies.values) {
            attachOwner(entry, owner: owner)
        }
    }

    private func detachFromDependencies(_ owner: ViewModelBinding) {
        for entry in Array(dependencies.values) {
            // A child callback may have propagated the same owner again.
            guard !isPropagated(owner) else { break }
            detachOwner(entry, owner: owner)
        }
    }

    private func attachOwner(_ entry: DependencyEntry, owner: ViewModelBinding) {
        guard
            !dependencyDisposed,
            !entry.handle.isDisposedAny,
            !entry.viewModel.isDisposed,
            !owner.isDisposed,
            dependencies[ObjectIdentifier(entry.handle)] === entry,
            isPropagated(owner)
        else { return }
        // The synchronous preflight above covers bindOwner's rejection cases.
        try? entry.handle.bindOwnerAny(owner, source: entry)
    }

    private func detachOwner(_ entry: DependencyEntry, owner: ViewModelBinding) {
        entry.handle.unbindOwnerAny(owner, source: entry)
    }
}
