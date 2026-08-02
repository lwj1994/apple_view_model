import Foundation

/// Stable dependency and lifecycle scope owned by one parent object generation.
@MainActor
final class ViewModelDependencyBinding: ViewModelBinding {
    private struct DependencyEntry {
        let handle: any _AnyHandle
        let viewModel: ViewModel
    }

    private weak var parent: ViewModel?
    private let onDependencyUpdate: (ViewModel) -> Void
    private var propagatedOwners: [ViewModelBinding] = []
    private var dependencies: [ObjectIdentifier: DependencyEntry] = [:]
    private var removeOwnerListener: (() -> Void)?
    private var dependencyDisposed = false

    override var isDependencyBinding: Bool { true }

    init(
        parent: ViewModel,
        parentHandler: ViewModelBindingHandler,
        onDependencyUpdate: @escaping (ViewModel) -> Void
    ) {
        self.parent = parent
        self.onDependencyUpdate = onDependencyUpdate
        super.init()

        propagatedOwners = parentHandler.constructionExternalOwners
        installDependencyHooks(
            attached: { [weak self] handle, viewModel in
                try self?.handleAttached(handle, viewModel: viewModel)
            },
            detached: { [weak self] handle, viewModel in
                self?.handleDetached(handle, viewModel: viewModel)
            },
            updated: { [weak self] viewModel in
                self?.onDependencyUpdate(viewModel)
            }
        )
        registerViewModelConstructionRollback { [weak self] in self?.dispose() }
        removeOwnerListener = parentHandler.addOwnerChangeListener { [weak self, weak parentHandler] _, _, _ in
            guard let self, let parentHandler else { return }
            self.syncOwners(parentHandler.externalOwners)
        }
    }

    public override func onUpdate() {
        // Disposal is forwarded by the source-aware handle hooks.
    }

    public override func dispose() {
        guard !dependencyDisposed else { return }
        dependencyDisposed = true
        removeOwnerListener?()
        removeOwnerListener = nil
        for owner in propagatedOwners {
            for entry in Array(dependencies.values) {
                detachOwner(entry.handle, viewModel: entry.viewModel, owner: owner)
            }
        }
        propagatedOwners.removeAll()
        super.dispose()
        dependencies.removeAll()
    }

    private func handleAttached(
        _ handle: any _AnyHandle,
        viewModel: ViewModel
    ) throws {
        try requireAcyclicDependency(viewModel)
        let key = ObjectIdentifier(handle)
        dependencies[key] = DependencyEntry(handle: handle, viewModel: viewModel)
        for owner in propagatedOwners {
            attachOwner(handle, viewModel: viewModel, owner: owner)
        }
        guard
            !dependencyDisposed,
            !handle.isDisposedAny,
            !viewModel.isDisposed
        else {
            // An `onBind` callback may synchronously recycle the child or tear
            // down this dependency scope before attachment commits. The handle
            // listener is not installed yet, so clean the provisional graph
            // entry explicitly and let the controller roll back its direct path.
            dependencies.removeValue(forKey: key)
            for owner in propagatedOwners {
                detachOwner(handle, viewModel: viewModel, owner: owner)
            }
            throw ViewModelError(
                "Cannot attach \(type(of: viewModel)): dependency was disposed during resolution."
            )
        }
    }

    private func handleDetached(_ handle: any _AnyHandle, viewModel: ViewModel) {
        dependencies.removeValue(forKey: ObjectIdentifier(handle))
        notifyDependency(viewModel)
    }

    private func notifyDependency(_ viewModel: ViewModel) {
        guard
            !dependencyDisposed,
            !InstanceManager.shared.isResetting,
            markViewModelBindingUpdated(self)
        else { return }
        onDependencyUpdate(viewModel)
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

        for owner in removed {
            for entry in Array(dependencies.values) {
                detachOwner(entry.handle, viewModel: entry.viewModel, owner: owner)
            }
            propagatedOwners.removeAll { $0 === owner }
        }
        for owner in added {
            propagatedOwners.append(owner)
            for entry in Array(dependencies.values) {
                attachOwner(entry.handle, viewModel: entry.viewModel, owner: owner)
            }
        }
    }

    private func attachOwner(
        _ handle: any _AnyHandle,
        viewModel: ViewModel,
        owner: ViewModelBinding
    ) {
        guard !handle.isDisposedAny, !viewModel.isDisposed else { return }
        // Register both sides before considering the propagation committed.
        // Either callback can synchronously dispose/remove `owner`; the final
        // membership check rolls back both sides if reentrancy invalidated it.
        viewModel.refHandler.addRef(owner, source: self)
        handle.bindAnyFrom(bindingId: owner.id, source: self)

        let dependencyStillAttached = dependencies[ObjectIdentifier(handle)] != nil
        let ownerStillPropagated = propagatedOwners.contains { $0 === owner }
        if dependencyDisposed
            || owner.isDisposed
            || !dependencyStillAttached
            || !ownerStillPropagated
            || handle.isDisposedAny
            || viewModel.isDisposed {
            detachOwner(handle, viewModel: viewModel, owner: owner)
        }
    }

    private func detachOwner(
        _ handle: any _AnyHandle,
        viewModel: ViewModel,
        owner: ViewModelBinding
    ) {
        if !viewModel.isDisposed {
            viewModel.refHandler.removeRef(owner, source: self)
        }
        if !handle.isDisposedAny {
            handle.unbindAnyFrom(bindingId: owner.id, source: self)
        }
    }
}
