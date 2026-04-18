import Foundation

/// Collects cleanup blocks and runs them in registration order during `dispose()`.
///
/// Corresponds to the Dart `AutoDisposeController`. `ViewModel.onDispose`
/// guarantees that one failing block does not skip subsequent ones.
@MainActor
public final class AutoDisposeController {
    private var blocks: [() -> Void] = []
    private var disposed = false

    public init() {}

    public func addDispose(_ block: @escaping () -> Void) {
        blocks.append(block)
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        for block in blocks {
            block()
        }
        blocks.removeAll()
    }
}
