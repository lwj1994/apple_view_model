import Foundation

/// Central registry keyed by ViewModel type. Equivalent to the Dart
/// `InstanceManager`.
///
/// Every concrete ViewModel class gets a dedicated `Store` keyed by
/// `ObjectIdentifier(T.self)`. `ViewModelBinding`, `ViewModel.readCached`, and
/// `ObservableValue` all go through this singleton to look up instances.
///
/// The manager is `@MainActor` so state mutations are race-free without a lock.
@MainActor
public final class InstanceManager {
    public static let shared = InstanceManager()

    private var stores: [ObjectIdentifier: AnyObject] = [:]

    private init() {}

    /// Return the typed store for `Value`, lazily creating it.
    func store<Value: AnyObject>(for type: Value.Type) -> Store<Value> {
        let id = ObjectIdentifier(type)
        if let cached = stores[id] as? Store<Value> {
            return cached
        }
        // Deferred-bind the newly-created store into the closure so we can compare
        // identities on cleanup without the "closure captures uninitialized value"
        // warning.
        var createdRef: Store<Value>?
        let created = Store<Value>(onStoreEmpty: { [weak self] in
            guard let self, let created = createdRef else { return }
            // Only drop the bucket if the current store really is the one we made,
            // and it is genuinely empty. This matches the Dart `if (!identical...)`
            // guard that defends against a replacement store being installed in the
            // same map slot.
            guard
                let current = self.stores[id] as? Store<Value>,
                ObjectIdentifier(current) == ObjectIdentifier(created),
                created.isEmpty
            else { return }
            self.stores.removeValue(forKey: id)
            created.dispose()
        })
        createdRef = created
        stores[id] = created
        return created
    }

    /// Convenience wrapper over `getHandle` that unwraps the instance.
    func get<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>? = nil
    ) throws -> Value {
        let handle = try getHandle(type, factory: factory)
        return try handle.requireInstance()
    }

    /// Same as `get` but returns `nil` on any failure.
    func maybeGet<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>? = nil
    ) -> Value? {
        do {
            return try get(type, factory: factory)
        } catch {
            return nil
        }
    }

    /// Rebuild an existing instance. Invoked only through `ViewModelBinding.recycle`.
    @discardableResult
    func recreate<Value: AnyObject>(_ value: Value, builder: (@MainActor () -> Value)? = nil) throws -> Value {
        try store(for: Value.self).recreate(value, builder: builder)
    }

    /// Unified handle resolver.
    ///
    /// - Empty factory (no builder, no key): find the newest handle, optionally
    ///   filtered by tag, and attach a new `bindingId` if one was supplied.
    /// - Non-empty factory: delegate to `Store.getHandle`.
    @discardableResult
    func getHandle<Value: AnyObject>(
        _ type: Value.Type,
        factory: InstanceFactory<Value>? = nil
    ) throws -> InstanceHandle<Value> {
        if factory == nil || factory!.isEmpty {
            let bindingId = factory?.arg.bindingId
            let tag = factory?.arg.tag
            let store = store(for: type)
            guard let found = try store.findNewlyInstance(tag: tag) else {
                throw ViewModelError("no \(type) instance found")
            }
            if let bindingId {
                // Re-wrap so that `Store.getHandle` sees the bindingId and calls
                // `bind` exactly like the key-based lookup path does.
                let extendFactory = InstanceFactory<Value>(
                    arg: InstanceArg(
                        key: found.arg.key,
                        tag: found.arg.tag,
                        bindingId: bindingId,
                        aliveForever: found.arg.aliveForever
                    )
                )
                return try store.getHandle(factory: extendFactory)
            }
            return found
        }
        return try store(for: type).getHandle(factory: factory!)
    }

    /// All handles that currently carry `tag` for the requested type.
    func getHandles<Value: AnyObject>(byTag tag: AnyHashable, type: Value.Type) -> [InstanceHandle<Value>] {
        store(for: type).instances(byTag: tag)
    }

    // MARK: - Test helpers

    /// Number of type buckets currently held — useful for leak checks.
    public var debugStoreCount: Int { stores.count }

    /// Drop every bucket, force-disposing any remaining handles. Intended for
    /// use between unit tests to guarantee isolation.
    public func debugReset() {
        let snapshot = stores
        stores.removeAll()
        for case let store as any _StoreDisposable in snapshot.values {
            store._disposeNow()
        }
    }
}

/// Non-generic erasure so a mixed-type store dictionary can be disposed uniformly.
@MainActor
protocol _StoreDisposable: AnyObject {
    func _disposeNow()
}

extension Store: _StoreDisposable {
    func _disposeNow() { dispose() }
}
