import Foundation

/// Aggregates multiple `ViewModelBindingPauseProvider` sources into a single
/// pause/resume signal. If **any** provider reports paused, the controller is
/// paused; only when **all** providers report resumed does it resume.
///
/// Equivalent to the Dart `PauseAwareController`.
@MainActor
public final class PauseAwareController {
    private let onPause: () -> Void
    private let onResume: () -> Void

    private var providers: [ProviderSlot] = []
    private var providerStates: [ObjectIdentifier: Bool] = [:]
    private(set) public var isPaused: Bool = false
    private var disposed = false

    public init(
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void
    ) {
        self.onPause = onPause
        self.onResume = onResume
    }

    public func addProvider(_ provider: any ViewModelBindingPauseProvider) {
        if disposed { return }
        let slot = ProviderSlot(provider: provider)
        if providers.contains(where: { $0.id == slot.id }) { return }
        providers.append(slot)
        subscribe(slot)
    }

    public func removeProvider(_ provider: any ViewModelBindingPauseProvider) {
        if disposed { return }
        let id = ObjectIdentifier(provider)
        providers.removeAll { slot in
            if slot.id == id {
                slot.task?.cancel()
                return true
            }
            return false
        }
        providerStates.removeValue(forKey: id)
        reevaluate()
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        for slot in providers {
            slot.task?.cancel()
        }
        providers.removeAll()
        providerStates.removeAll()
    }

    // MARK: - Internals

    private func subscribe(_ slot: ProviderSlot) {
        let stream = slot.provider.pauseStateChanges
        let id = slot.id
        slot.task = Task { @MainActor [weak self] in
            for await shouldPause in stream {
                guard let self, !self.disposed else { return }
                self.providerStates[id] = shouldPause
                self.reevaluate()
            }
        }
    }

    private func reevaluate() {
        if disposed { return }
        let anyPaused = providerStates.values.contains(true)
        guard anyPaused != isPaused else { return }
        isPaused = anyPaused
        if isPaused {
            onPause()
        } else {
            onResume()
        }
    }

    /// Holds a provider together with the task iterating its pause stream, so
    /// `removeProvider` / `dispose` can cancel the iteration cleanly.
    private final class ProviderSlot {
        let id: ObjectIdentifier
        let provider: any ViewModelBindingPauseProvider
        var task: Task<Void, Never>?

        init(provider: any ViewModelBindingPauseProvider) {
            self.id = ObjectIdentifier(provider)
            self.provider = provider
        }
    }
}
