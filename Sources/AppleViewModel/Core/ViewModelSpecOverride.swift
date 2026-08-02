import Foundation

/// One identity-tracked override entry. Entries are removed by identity so an
/// out-of-order restore never revives an override that has already ended.
@MainActor
private final class ViewModelSpecOverrideEntry {
    let spec: AnyObject

    init(spec: AnyObject) {
        self.spec = spec
    }
}

/// Task-local override scope used by `runWithOverride`.
///
/// The object is only mutated from `@MainActor`; `@unchecked Sendable` is used
/// solely so Swift task-local storage can carry the reference across suspension
/// points while actor isolation remains the synchronization mechanism.
@MainActor
private final class ViewModelSpecOverrideContext: @unchecked Sendable {
    let parent: ViewModelSpecOverrideContext?
    private var entries: [ObjectIdentifier: [ViewModelSpecOverrideEntry]] = [:]

    init(parent: ViewModelSpecOverrideContext?) {
        self.parent = parent
    }

    func append(
        _ entry: ViewModelSpecOverrideEntry,
        for owner: ObjectIdentifier
    ) {
        entries[owner, default: []].append(entry)
    }

    func remove(
        _ entry: ViewModelSpecOverrideEntry,
        for owner: ObjectIdentifier
    ) {
        guard var current = entries[owner] else { return }
        current.removeAll { $0 === entry }
        if current.isEmpty {
            entries.removeValue(forKey: owner)
        } else {
            entries[owner] = current
        }
    }

    func activeSpec(for owner: ObjectIdentifier) -> AnyObject? {
        if let current = entries[owner]?.last {
            return current.spec
        }
        return parent?.activeSpec(for: owner)
    }
}

private enum ViewModelSpecOverrideTaskValues {
    @TaskLocal static var context: ViewModelSpecOverrideContext?
}

/// Shared proxy mechanics for every zero-to-four-argument spec variant.
///
/// `setProxy` remains the legacy process-global fallback. `overrideWith`
/// installs an identity-tracked scoped entry and returns an idempotent restore
/// closure. `runWithOverride` adds task-local isolation, so overlapping async
/// operations cannot observe one another's mocks.
@MainActor
final class ViewModelSpecProxyState<Spec: AnyObject> {
    private var legacyProxy: Spec?
    private var manualEntries: [ViewModelSpecOverrideEntry] = []

    var activeProxy: Spec? {
        let owner = ObjectIdentifier(self)
        if let scoped = ViewModelSpecOverrideTaskValues.context?
            .activeSpec(for: owner) as? Spec {
            return scoped
        }
        return manualEntries.last?.spec as? Spec ?? legacyProxy
    }

    func setProxy(_ spec: Spec) {
        legacyProxy = spec
    }

    func clearProxy() {
        legacyProxy = nil
    }

    func overrideWith(_ spec: Spec) -> @MainActor () -> Void {
        let owner = ObjectIdentifier(self)
        let entry = ViewModelSpecOverrideEntry(spec: spec)
        let context = ViewModelSpecOverrideTaskValues.context
        if let context {
            context.append(entry, for: owner)
        } else {
            manualEntries.append(entry)
        }

        var restored = false
        return { @MainActor [weak self, weak context] in
            guard !restored else { return }
            restored = true
            if let context {
                context.remove(entry, for: owner)
            } else {
                self?.manualEntries.removeAll { $0 === entry }
            }
        }
    }

    func runWithOverride<Result>(
        _ spec: Spec,
        operation: @escaping @MainActor () async throws -> Result
    ) async rethrows -> Result {
        let context = ViewModelSpecOverrideContext(
            parent: ViewModelSpecOverrideTaskValues.context
        )
        let owner = ObjectIdentifier(self)
        let entry = ViewModelSpecOverrideEntry(spec: spec)
        context.append(entry, for: owner)

        return try await ViewModelSpecOverrideTaskValues.$context.withValue(context) {
            defer { context.remove(entry, for: owner) }
            return try await operation()
        }
    }
}
