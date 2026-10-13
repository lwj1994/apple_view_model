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

    private weak var parent: ViewModel?
    private var propagatedOwners: [ViewModelBinding] = []
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

        propagatedOwners = parentHandler.constructionExternalOwners
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
        removeOwnerListener = parentHandler.addOwnerChangeListener { [weak self, weak parentHandler] _, _, _ in
            guard let self, let parentHandler else { return }
            self.syncOwners(parentHandler.externalOwners)
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
            for owner in Array(self.propagatedOwners) {
                self.attachOwner(entry, owner: owner)
            }
        }
    }

    private func handleDetached(_ handle: any _AnyHandle) -> (() -> Void)? {
        guard let entry = dependencies.removeValue(forKey: ObjectIdentifier(handle)) else { return nil }
        let owners = propagatedOwners
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

    private func syncOwners(_ currentOwners: [ViewModelBinding]) {
        guard !dependencyDisposed else { return }
        let removed = propagatedOwners.filter { owner in
            !currentOwners.contains { $0 === owner }
        }
        let added = currentOwners.filter { owner in
            !propagatedOwners.contains { $0 === owner }
        }

        // Commit this projection before child callbacks can reenter sync.
        propagatedOwners = currentOwners
        for owner in removed {
            for entry in Array(dependencies.values) {
                guard !propagatedOwners.contains(where: { $0 === owner }) else { break }
                detachOwner(entry, owner: owner)
            }
        }
        for owner in added {
            for entry in Array(dependencies.values) {
                attachOwner(entry, owner: owner)
            }
        }
    }

    private func attachOwner(_ entry: DependencyEntry, owner: ViewModelBinding) {
        guard
            !dependencyDisposed,
            !entry.handle.isDisposedAny,
            !entry.viewModel.isDisposed,
            !owner.isDisposed,
            dependencies[ObjectIdentifier(entry.handle)] === entry,
            propagatedOwners.contains(where: { $0 === owner })
        else { return }
        // The synchronous preflight above covers bindOwner's rejection cases.
        try? entry.handle.bindOwnerAny(owner, source: entry)
    }

    private func detachOwner(_ entry: DependencyEntry, owner: ViewModelBinding) {
        entry.handle.unbindOwnerAny(owner, source: entry)
    }
}
