import Foundation

/// Per-type instance registry, equivalent to the Dart `Store<T>`.
///
/// `InstanceManager` creates one store per concrete ViewModel type. Each store:
/// - caches handles by `key`,
/// - assigns creation indices via `nextIndex` so `findNewlyInstance` can return
///   the most recently created instance,
/// - listens for its handles' dispose actions and evicts them from the cache,
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

    /// Every handle that carries the supplied tag, sorted most-recent-first.
    func instances(byTag tag: AnyHashable) -> [InstanceHandle<Value>] {
        guard !disposed else {
            // Returning an empty slice avoids a throw path on an already-discarded
            // manager; the caller that reached us here has nothing useful to do.
            return []
        }
        return handles.values
            .filter { $0.arg.tag == tag }
            .sorted { $0.index > $1.index }
    }

    /// The highest-index handle that still matches the (optional) tag filter.
    func findNewlyInstance(tag: AnyHashable? = nil) throws -> InstanceHandle<Value>? {
        guard !disposed else {
            throw ViewModelError("Store<\(Value.self)> has been disposed.")
        }
        if handles.isEmpty { return nil }
        if let tag {
            return instances(byTag: tag).first
        }
        return handles.values.max(by: { $0.index < $1.index })
    }

    /// Get-or-create. Mirrors the Dart `getNotifier`:
    /// 1. Look up `factory.arg.key` in the cache; if present, record an extra
    ///    `bind(bindingId)` when supplied and return it.
    /// 2. Otherwise run the builder, register the new handle, and subscribe so we
    ///    can remove it from the cache on dispose.
    @discardableResult
    func getHandle(factory: InstanceFactory<Value>) throws -> InstanceHandle<Value> {
        guard !disposed else {
            throw ViewModelError("Store<\(Value.self)> has been disposed.")
        }
        let realKey: AnyHashable = factory.arg.key ?? AnyHashable(UUID())
        let bindingId = factory.arg.bindingId
        let arg = factory.arg.copy(key: .some(realKey))

        if let cached = handles[realKey] {
            if let bindingId, !cached.contains(bindingId: bindingId) {
                cached.bind(bindingId)
            }
            return cached
        }

        guard let builder = factory.builder else {
            throw ViewModelError("\(Value.self) factory is nil and cache miss.")
        }

        let instance = builder()
        let created = InstanceHandle<Value>(
            value: instance,
            arg: arg,
            index: nextIndex,
            factory: builder
        )
        nextIndex += 1
        handles[realKey] = created

        // Watch for dispose so we can evict the handle from the cache.
        // The handle discards its listener list during dispose, so no explicit
        // unsubscribe is needed.
        _ = created.addListener { [weak self] handle in
            guard let self else { return }
            guard handle.currentAction == .dispose else { return }
            self.handles.removeValue(forKey: realKey)
            if self.handles.isEmpty {
                self.onStoreEmpty?()
            }
        }

        return created
    }

    /// Recreate an existing instance — used by `InstanceManager.recreate`.
    func recreate(_ target: Value, builder: (@MainActor () -> Value)? = nil) throws -> Value {
        guard !disposed else {
            throw ViewModelError("Store<\(Value.self)> has been disposed.")
        }
        guard let handle = handles.values.first(where: { $0.value === target }) else {
            throw ViewModelError("Cannot recreate \(Value.self) instance. Instance not found in store.")
        }
        return try handle.recreate(builder: builder)
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
}
