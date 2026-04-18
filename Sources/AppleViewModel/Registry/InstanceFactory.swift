import Foundation

/// Parameter bundle for `Store.getHandle`, matching the Dart `InstanceFactory`.
///
/// - `builder`: If `nil`, `Store.getHandle` performs a cache lookup only and
///   throws on miss. Supplying a builder turns the call into "get or create".
/// - `arg`: Carries `key`, `tag`, `bindingId`, and `aliveForever`.
struct InstanceFactory<Value: AnyObject> {
    let builder: (@MainActor () -> Value)?
    let arg: InstanceArg

    init(builder: (@MainActor () -> Value)? = nil, arg: InstanceArg = InstanceArg()) {
        self.builder = builder
        self.arg = arg
    }

    /// A factory with neither a builder nor a key — used to express "find the most
    /// recent instance, optionally filtered by tag".
    var isEmpty: Bool {
        builder == nil && arg.key == nil
    }

    func copy(builder: (@MainActor () -> Value)? = nil, arg: InstanceArg? = nil) -> InstanceFactory<Value> {
        InstanceFactory(builder: builder ?? self.builder, arg: arg ?? self.arg)
    }
}
