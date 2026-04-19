import Foundation
import Combine

/// Base class for business ViewModels, equivalent to the Dart `mixin ViewModel`.
///
/// Swift has no mixins, so subclassing takes the place of `with ViewModel`.
/// Any subclass automatically gains:
/// - listener registration and fan-out (`listen`, `notifyListeners`, `update`),
/// - lifecycle hooks (`onCreate`, `onBind`, `onUnbind`, `onDispose`),
/// - cleanup registration (`addDispose`),
/// - access to the owning binding via `viewModelBinding`, which resolves through
///   a `TaskLocal` (the Swift analogue of the Dart `Zone` used by the original
///   package).
///
/// Every `ViewModel` is also a SwiftUI `ObservableObject`: `notifyListeners()`
/// emits `objectWillChange` before fanning out to the internal listener list,
/// so instances can be handed directly to `@StateObject` / `@ObservedObject`.
///
/// Instances are typically created by a `ViewModelBinding` via a
/// `ViewModelSpec`. Static entry points (`ViewModel.initialize`,
/// `ViewModel.readCached`) are provided for app-wide setup and lookup.
@MainActor
open class ViewModel: InstanceLifeCycle, ObservableObject {
    // MARK: - Global configuration

    private static var _lifecycles: [any ViewModelLifecycle] = []
    private static var _initialized = false

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
        if _initialized { return }
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

    /// Test-only hook: reset the global configuration and lifecycle list.
    public static func debugReset() {
        _initialized = false
        ViewModelGlobalConfig.reset()
        _lifecycles.removeAll()
    }

    // MARK: - Static cache lookup

    /// Fetch a cached ViewModel by key or tag. Throws `ViewModelError` when no match is found
    /// or when the match has already been disposed.
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
            } catch is ViewModelError where tag == nil {
                throw ViewModelError("no \(T.self) instance found")
            } catch {
                if tag == nil { throw error }
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

    /// Same as `readCached` but returns `nil` on miss instead of throwing.
    public static func maybeReadCached<T: ViewModel>(
        key: AnyHashable? = nil,
        tag: AnyHashable? = nil
    ) -> T? {
        try? readCached(key: key, tag: tag)
    }

    // MARK: - Per-instance state

    public internal(set) var instanceArg: InstanceArg = InstanceArg()
    public private(set) var isDisposed: Bool = false

    public var tag: AnyHashable? { instanceArg.tag }

    private var listeners: [UUID: () -> Void] = [:]
    public var hasListeners: Bool { !listeners.isEmpty }

    private let autoDispose = AutoDisposeController()

    /// Internal dependency resolver. Exposed via `@_spi(Internal)` to the rest of the
    /// framework; consumers access bindings through `viewModelBinding` instead.
    @_spi(Internal) public let refHandler = ViewModelBindingHandler()

    /// Entry point used inside a ViewModel subclass to access other ViewModels.
    ///
    /// Resolution order (driven by `refHandler`):
    /// 1. Parent binding injected by the registry when the VM was created.
    /// 2. The binding stored in `ViewModelBinding.current` (a `@TaskLocal`).
    /// 3. Trap — using `viewModelBinding` outside any binding context is a programmer error.
    open var viewModelBinding: ViewModelBinding {
        refHandler.binding
    }

    public init() {}

    // MARK: - Listener API

    /// Subscribe to change notifications. Returns a closure that cancels the subscription.
    @discardableResult
    public func listen(onChanged: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listeners[id] = onChanged
        return { [weak self] in
            self?.listeners.removeValue(forKey: id)
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
        objectWillChange.send()
        // Snapshot first so callbacks can add / remove listeners without breaking iteration.
        let snapshot = Array(listeners.values)
        for listener in snapshot {
            do {
                try runCatching(listener)
            } catch {
                reportViewModelError(
                    error, type: .listener, context: "notifyListeners error")
            }
        }
    }

    /// Run `block` synchronously and then call `notifyListeners()` exactly once.
    public func update(_ block: () -> Void) {
        block()
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
