import Foundation
import Combine

/// Base class for business ViewModels, equivalent to the Dart `mixin ViewModel`.
///
/// Swift has no mixins, so subclassing takes the place of `with ViewModel`.
/// Any subclass automatically gains:
/// - listener registration and fan-out (`listen`, `notifyListeners`, `update`),
/// - lifecycle hooks (`onCreate`, `onBind`, `onUnbind`, `onDispose`),
/// - cleanup registration (`addDispose`),
/// - a stable generation-owned `viewModelBinding` for resolving child modules.
///
/// Every `ViewModel` is also a SwiftUI `ObservableObject`: `notifyListeners()`
/// emits `objectWillChange` before fanning out to the internal listener list,
/// so instances can be handed directly to `@StateObject` / `@ObservedObject`.
///
/// Instances should normally be resolved by a `ViewModelBinding` from a stable
/// `ViewModelSpec`. Static cache lookup is an advanced escape hatch for querying
/// an instance already created by another owner.
@MainActor
open class ViewModel: InstanceLifeCycle, ObservableObject {
    // MARK: - Global configuration

    private static var _lifecycles: [any ViewModelLifecycle] = []
    private static var _initialized = false
    private static var _isResetting = false

    /// Snapshot of the global configuration.
    ///
    /// Backed by a lock-protected container, so this accessor is safe from any
    /// isolation domain — including background `Task`s and `@Sendable` callbacks.
    /// This is what lets `viewModelLog` / `reportViewModelError` escape `@MainActor`.
    public nonisolated static var config: ViewModelConfig {
        ViewModelGlobalConfig.current
    }

    /// Install the global configuration once per process. Subsequent calls are ignored.
    ///
    /// - Parameters:
    ///   - config: Custom configuration. Optional.
    ///   - lifecycles: Observers that receive create/bind/unbind/dispose events for every
    ///     ViewModel in the process.
    public static func initialize(
        config: ViewModelConfig = ViewModelConfig(),
        lifecycles: [any ViewModelLifecycle] = []
    ) {
        if _initialized || _isResetting { return }
        _initialized = true
        ViewModelGlobalConfig.set(config)
        _lifecycles.append(contentsOf: lifecycles)
    }

    /// Add a global lifecycle observer. Returns a disposer closure that removes it.
    @discardableResult
    public static func addLifecycle(_ lifecycle: any ViewModelLifecycle) -> () -> Void {
        _lifecycles.append(lifecycle)
        return {
            _lifecycles.removeAll { $0 === lifecycle }
        }
    }

    public static func removeLifecycle(_ lifecycle: any ViewModelLifecycle) {
        _lifecycles.removeAll { $0 === lifecycle }
    }

    /// Completely resets the ViewModel runtime for test/process isolation.
    ///
    /// Every cached generation is force-disposed, including `aliveForever`
    /// entries. Configuration and lifecycle observers are cleared, and the
    /// runtime may be initialized again afterward.
    public static func reset() {
        // Cover the whole reset, not only registry disposal. A nested reset
        // triggered by one instance's teardown must not clear configuration or
        // lifecycle observers while the outer reset is still disposing peers.
        guard !_isResetting else { return }
        _isResetting = true
        defer { _isResetting = false }

        InstanceManager.shared.debugReset()
        _initialized = false
        ViewModelGlobalConfig.reset()
        _lifecycles.removeAll()
    }

    @available(*, deprecated, renamed: "reset")
    public static func debugReset() {
        reset()
    }

    // MARK: - Static cache lookup

    /// Advanced lookup-only API. Fetch an already-created ViewModel by key or
    /// tag. Throws `ViewModelError` when no match is found or when the match has
    /// already been disposed. Prefer `ViewModelBinding.read(_:)` with a stable
    /// spec for normal dependency resolution.
    public static func readCached<T: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) throws -> T {
        var found: T?
        if let key {
            do {
                found = try InstanceManager.shared.get(
                    T.self,
                    factory: InstanceFactory(arg: InstanceArg(key: key))
                )
            } catch is ViewModelError {
                if tag == nil {
                    throw ViewModelError("no \(T.self) instance found")
                }
                // Expected key miss: fall through to the optional tag lookup.
            } catch {
                // Only a ViewModelError represents an expected cache miss.
                throw error
            }
        }
        if found == nil {
            found = try InstanceManager.shared.get(
                T.self,
                factory: InstanceFactory(arg: InstanceArg(tag: tag))
            )
        }
        guard let vm = found else {
            throw ViewModelError("no \(T.self) instance found")
        }
        if vm.isDisposed {
            throw ViewModelError("\(T.self) is disposed")
        }
        return vm
    }

    /// Advanced lookup-only API. Same as `readCached` but returns `nil` on a
    /// lookup failure. Prefer spec-based resolution in normal code.
    public static func maybeReadCached<T: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) -> T? {
        try? maybeReadCachedThrowing(key: key, tag: tag)
    }

    /// Recoverable counterpart of `maybeReadCached` that preserves unexpected
    /// non-ViewModel errors while returning `nil` for framework lookup errors.
    public static func maybeReadCachedThrowing<T: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) throws -> T? {
        do {
            return try readCached(key: key, tag: tag)
        } catch is ViewModelError {
            return nil
        } catch {
            throw error
        }
    }

    // MARK: - Per-instance state

    public internal(set) var instanceArg: InstanceArg = InstanceArg()
    public private(set) var isDisposed: Bool = false

    public var tag: AnyHashable? { instanceArg.tag }

    private struct ListenerEntry {
        let id: UUID
        let callback: () throws -> Void
    }

    private var listeners: [ListenerEntry] = []
    public var hasListeners: Bool { !listeners.isEmpty }

    private let autoDispose = AutoDisposeController()
    private var dependencyBinding: ViewModelDependencyBinding?

    /// Source-aware owner diagnostics for this ViewModel generation.
    @_spi(Internal) public let refHandler = ViewModelBindingHandler()

    /// Stable dependency scope owned by this object generation.
    open var viewModelBinding: ViewModelBinding {
        precondition(
            !isDisposed,
            "Cannot resolve dependencies from a disposed \(type(of: self))."
        )
        if let dependencyBinding { return dependencyBinding }
        let created = ViewModelDependencyBinding(
            parent: self,
            parentHandler: refHandler,
            onDependencyUpdate: { [weak self] dependency in
                self?.handleDependencyUpdate(dependency)
            }
        )
        dependencyBinding = created
        return created
    }

    var dependencyBindingIfCreated: ViewModelDependencyBinding? { dependencyBinding }

    public init() {}

    // MARK: - Listener API

    /// Subscribe to change notifications. Returns a closure that cancels the subscription.
    @discardableResult
    public func listen(onChanged: @escaping () throws -> Void) -> () -> Void {
        let id = UUID()
        listeners.append(ListenerEntry(id: id, callback: onChanged))
        return { [weak self] in
            self?.listeners.removeAll { $0.id == id }
        }
    }

    /// Fan out a change notification to all subscribers.
    ///
    /// Also emits `objectWillChange` so SwiftUI views holding the instance via
    /// `@StateObject` / `@ObservedObject` re-render on the next run loop tick.
    ///
    /// After the instance has been disposed this is a no-op (logged at debug level).
    public func notifyListeners() {
        if isDisposed {
            viewModelLog("\(type(of: self)): notifyListeners after Disposed")
            return
        }
        runInViewModelUpdateTransaction {
            objectWillChange.send()
            // Snapshot first so callbacks can add / remove listeners without breaking iteration.
            let snapshot = listeners
            for entry in snapshot {
                guard listeners.contains(where: { $0.id == entry.id }) else { continue }
                do {
                    try entry.callback()
                } catch {
                    reportViewModelError(
                        error, type: .listener, context: "notifyListeners error")
                }
            }
        }
    }

    /// Called before a watched child update is forwarded through this ViewModel.
    open func onDependencyNotify(_ viewModel: ViewModel) {}

    private func handleDependencyUpdate(_ dependency: ViewModel) {
        guard !isDisposed else { return }
        onDependencyNotify(dependency)
        notifyListeners()
    }

    /// Run `block` synchronously and notify exactly once after success.
    /// A thrown error is propagated and does not produce a notification.
    public func update(_ block: () throws -> Void) rethrows {
        try block()
        notifyListeners()
    }

    /// `async` counterpart of `update(_:)`.
    public func update(_ block: () async throws -> Void) async rethrows {
        try await block()
        notifyListeners()
    }

    /// Register a cleanup closure. All registered blocks run in registration order
    /// during `onDispose`.
    public func addDispose(_ block: @escaping () -> Void) {
        autoDispose.addDispose(block)
    }

    // MARK: - InstanceLifeCycle

    /// Called by the registry immediately after the instance is stored. Always call
    /// `super` when overriding.
    open func onCreate(_ arg: InstanceArg) {
        instanceArg = arg
        for lifecycle in Self._lifecycles {
            do {
                try runCatching { lifecycle.onCreate(self, arg: arg) }
            } catch {
                reportViewModelError(
                    error, type: .lifecycle, context: "Lifecycle observer onCreate error")
            }
        }
    }

    open func onBind(_ arg: InstanceArg, bindingId: String) {
        for lifecycle in Self._lifecycles {
            do {
                try runCatching { lifecycle.onBind(self, arg: arg, bindingId: bindingId) }
            } catch {
                reportViewModelError(
                    error, type: .lifecycle, context: "Lifecycle observer onBind error")
            }
        }
    }

    open func onUnbind(_ arg: InstanceArg, bindingId: String) {
        for lifecycle in Self._lifecycles {
            do {
                try runCatching { lifecycle.onUnbind(self, arg: arg, bindingId: bindingId) }
            } catch {
                reportViewModelError(
                    error, type: .lifecycle, context: "Lifecycle observer onUnbind error")
            }
        }
    }

    open func onDispose(_ arg: InstanceArg) {
        isDisposed = true
        do {
            try runCatching { autoDispose.dispose() }
        } catch {
            reportViewModelError(
                error, type: .dispose, context: "\(type(of: self)) autoDispose error")
        }
        do {
            try runCatching { dependencyBinding?.dispose() }
        } catch {
            reportViewModelError(
                error, type: .dispose,
                context: "\(type(of: self)) dependency binding dispose error")
        }
        do {
            try runCatching { refHandler.dispose() }
        } catch {
            reportViewModelError(
                error, type: .dispose, context: "\(type(of: self)) refHandler dispose error")
        }
        do {
            try runCatching { dispose() }
        } catch {
            reportViewModelError(
                error, type: .dispose, context: "\(type(of: self)) dispose() error")
        }
        for lifecycle in Self._lifecycles {
            do {
                try runCatching { lifecycle.onDispose(self, arg: arg) }
            } catch {
                reportViewModelError(
                    error, type: .dispose, context: "Lifecycle observer onDispose error")
            }
        }
        listeners.removeAll()
    }

    /// Subclass hook for custom teardown. No `super` call needed; the base does nothing.
    open func dispose() {}

    // MARK: - Private

    /// Converts a non-throwing block into a `throws` context so errors from platform
    /// APIs (e.g. `NSException` bridging) can be surfaced through a uniform `catch`.
    private func runCatching(_ block: () throws -> Void) throws {
        try block()
    }
}
