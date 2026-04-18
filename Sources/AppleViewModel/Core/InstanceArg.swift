import Foundation

/// Metadata used when creating or looking up a managed ViewModel instance.
///
/// Corresponds to the Dart `InstanceArg` struct.
///
/// - `key`: Cache key. Instances with the same `key` are the same object in the registry.
/// - `tag`: Logical grouping label. Multiple instances may share a tag; used by
///   `readCachesByTag` / `watchCachesByTag`.
/// - `bindingId`: The id of the `ViewModelBinding` that owns the reference being added.
///   Drives the reference-counted lifetime model.
/// - `aliveForever`: When true, the instance is not disposed even when `bindingIds`
///   drops to zero.
public struct InstanceArg: Hashable {
    public let key: AnyHashable?
    public let tag: AnyHashable?
    public let bindingId: String?
    public let aliveForever: Bool

    public init(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil,
        bindingId: String? = nil,
        aliveForever: Bool = false
    ) {
        self.key = key
        self.tag = tag
        self.bindingId = bindingId
        self.aliveForever = aliveForever
    }

    /// Immutable copy-with.
    ///
    /// Because Swift cannot distinguish between "not provided" and "explicitly nil" in a
    /// single parameter, each optional field is wrapped in a double `Optional` so callers can
    /// pass `.some(nil)` to force the field to nil, or omit the argument to keep the
    /// current value.
    public func copy(
        key: AnyHashable?? = nil,
        tag: AnyHashable?? = nil,
        bindingId: String?? = nil,
        aliveForever: Bool? = nil
    ) -> InstanceArg {
        InstanceArg(
            key: key ?? self.key,
            tag: tag ?? self.tag,
            bindingId: bindingId ?? self.bindingId,
            aliveForever: aliveForever ?? self.aliveForever
        )
    }
}
