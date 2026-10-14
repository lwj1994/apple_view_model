import Foundation

/// Per-type instance registry, equivalent to the Dart `Store<T>`.
///
/// `InstanceManager` creates one store per concrete ViewModel type. Each store:
/// - caches handles by `key`,
/// - assigns creation indices via `nextIndex` so `findNewlyInstance` can return
///   the most recently created instance,
/// - listens for handle disposal notifications and evicts them from the cache,
/// - invokes `onStoreEmpty` once the map has been drained so the manager can
///   release the bucket entirely.
@MainActor
final class Store<Value: AnyObject> {
    private var handles: [AnyHashable: InstanceHandle<Value>] = [:]
    private var nextIndex: Int = 0
    private var disposed = false

    private let onStoreEmpty: (() -> Void)?

    init(onStoreEmpty: (() -> Void)? = nil) {
        self.onStoreEmpty = onStoreEmpty
    }

    var isEmpty: Bool { handles.isEmpty }

    func containsLiveKey(_ key: AnyHashable) -> Bool { handles[key]?.isDisposed == false }

    /// Every resolvable handle carrying the tag, sorted most-recent-first.
    func instances(byTag tag: AnyHashable) -> [InstanceHandle<Value>] {
        guard !disposed else {
            // Returning an empty slice avoids a throw path on an already-discarded
            // manager; the caller that reached us here has nothing useful to do.
            return []
        }
        // Forced disposal marks a handle unavailable before onUnbind callbacks
        // run, but eviction follows later. Reentrant lookups must skip it.
        return handles.values
            .filter { !$0.isDisposed && $0.arg.tag == tag }
            .sorted { $0.index > $1.index }
    }

    /// The highest-index resolvable handle matching the (optional) tag filter.
    func findNewlyInstance(tag: AnyHashable? = nil) throws -> InstanceHandle<Value>? {
        guard !disposed else {
            throw ViewModelError("Store<\(Value.self)> has been disposed.")
        }
        // Single-result lookups need only the highest creation index, not the
        // sorted batch. Scan each live handle once; recycling the newest then
        // naturally reveals the next one without maintaining another cache.
        var newest: InstanceHandle<Value>?
        for handle in handles.values {
            guard !handle.isDisposed else { continue }
            if let tag, handle.arg.tag != tag { continue }
            if let current = newest, current.index >= handle.index { continue }
            newest = handle
        }
        return newest
    }

    /// Number of resolvable cached handles, optionally filtered by tag.
    /// A disposing handle is already unavailable even before cache eviction.
    func countInstances(tag: AnyHashable? = nil) -> Int {
        guard !disposed else { return 0 }
        var count = 0
        for handle in handles.values {
            guard !handle.isDisposed else { continue }
            if let tag, handle.arg.tag != tag { continue }
            count += 1
        }
        return count
    }

    /// Resolve from the cache or construct and register a new generation.
    /// Managed callers attach through onResolve after cache eviction tracking
    /// is installed, so onBind can safely reenter resolution or disposal.
    @discardableResult
    func getHandle(
        factory: InstanceFactory<Value>,
        onResolve: ((InstanceHandle<Value>) throws -> Void)? = nil
    ) throws -> InstanceHandle<Value> {
        guard !disposed else {
            throw ViewModelError("Store<\(Value.self)> has been disposed.")
        }
        if factory.arg.aliveForever, factory.arg.key == nil {
            throw ViewModelError(
                "An aliveForever instance must use an explicit key."
            )
        }
        let realKey: AnyHashable = factory.arg.key ?? AnyHashable(ViewModelPrivateKey())
        let bindingId = factory.arg.bindingId
        let arg = factory.arg.copy(key: .some(realKey))

        if let cached = handles[realKey] {
            // A visible owner id can reach this handle directly and through a
            // parent. bind() records the direct source independently.
            if let onResolve {
                try onResolve(cached)
            } else {
                cached.bind(bindingId)
            }
            return cached
        }

        guard let builder = factory.builder else {
            throw ViewModelError("\(Value.self) factory is nil and cache miss.")
        }

        let created = try runInViewModelConstruction(
            Value.self,
            key: realKey,
            isImplicit: realKey.base is ViewModelPrivateKey
        ) {
            let instance = try builder()
            if disposed {
                disposeUntrackedInstance(instance, arg: arg)
                throw ViewModelError(
                    "Cannot create \(Value.self) because its Store was disposed while "
                        + "the factory builder was running. The new instance was disposed "
                        + "and was not cached."
                )
            }
            // Reserve the index before onCreate/onBind can synchronously
            // construct another instance of this type with a different key.
            let creationIndex = nextIndex
            nextIndex += 1
            return InstanceHandle<Value>(
                value: instance,
                arg: arg,
                index: creationIndex,
                bindOnCreate: onResolve == nil
            )
        }
        if disposed {
            created.unbindAll(force: true)
            throw ViewModelError(
                "Cannot create \(Value.self) because its Store was disposed during "
                    + "instance creation. The new instance was disposed and was not cached."
            )
        }
        handles[realKey] = created

        // Watch for dispose so we can evict the handle from the cache.
        // The handle discards its listener list during dispose, so no explicit
        // unsubscribe is needed.
        _ = created.addListener { [weak self] _ in
            guard let self else { return }
            self.handles.removeValue(forKey: realKey)
            if self.handles.isEmpty {
                self.onStoreEmpty?()
            }
        }

        do {
            try onResolve?(created)
        } catch {
            // Only this cache-miss generation is tentative. A reentrant owner
            // may already have claimed it; preserve that owner's generation.
            if !created.isDisposed, created.bindingIds.isEmpty {
                created.unbindAll(force: true)
            }
            throw error
        }
        return created
    }

    func tryRecycle(_ target: AnyObject) -> Bool {
        guard !disposed else { return false }
        guard let handle = handles.values.first(where: { $0.value === target }) else {
            return false
        }
        handle.unbindAll(force: true)
        return true
    }

    /// Store-wide teardown. Forces every remaining handle to dispose so no leak survives.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        let snapshot = Array(handles.values)
        for handle in snapshot {
            handle.unbindAll(force: true)
        }
        handles.removeAll()
    }

    private func disposeUntrackedInstance(_ target: Value, arg: InstanceArg) {
        guard let lifecycle = target as? InstanceLifeCycle else { return }
        lifecycle.onDispose(arg)
    }
}
