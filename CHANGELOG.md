# Changelog

All notable changes to AppleViewModel will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.0] - 2026-08-02

### Added

- Add an English, skill-local Instagram architecture example showing a
  multi-root SwiftUI app composed from API, repository, user, feed,
  post-detail, comment, and startup-coordinator ViewModels.
- Add nested/idempotent `overrideWith` and task-local async
  `runWithOverride` for base and parameterized specs.
- Add `throwingBuilder` plus recoverable `watchThrowing` / `readThrowing`
  resolution alongside the source-compatible fail-fast `watch` / `read` APIs.
- Add the strongly typed SwiftUI `StateViewModelSelector` with optional local
  equality.

### Changed

- `ViewModel.reset()` now force-disposes every cached generation, including
  `aliveForever`, rejects reentrant creation, clears configuration/lifecycle
  state only after teardown, and permits re-initialization.
- Listener and state-listener dispatch uses ordered token snapshots, isolates
  throwing callbacks, preserves frozen diffs across reentrant updates, and
  applies selector equality as local → global → `Equatable`.
- SwiftUI ViewModel/cached hosts re-resolve after recycle, and state selector
  hosts rebuild subscriptions when the VM generation changes.
- Existing non-throwing `maybe*Cached` APIs remain source-compatible; new
  `maybe*CachedThrowing` counterparts return `nil` for `ViewModelError` while
  preserving unexpected errors. A throwing global error handler is itself
  caught and logged.

### Fixed

- Keep SwiftUI watch/read and cached hosts aligned with the latest factory,
  key, tag, selector, and equality inputs while correctly following recycled
  ViewModel generations.
- Roll back provisional owner and dependency attachments when construction,
  lifecycle reentrancy, or cycle validation aborts resolution, including newly
  created `aliveForever` generations.

### Removed

- Remove `ObservableValue`, `ObservableStateViewModel`, and SwiftUI
  `ObserverBuilder` APIs to match Flutter `view_model` 1.1.0.

## [0.5.0] - 2026-07-27

### Removed

- Remove the public `ViewModelBinding.recreate(_:builder:)` API together with
  Manager, Store, and `InstanceHandle` in-place replacement logic, plus all
  `InstanceAction` / `currentAction` bookkeeping.
- Remove the SwiftUI `ViewModelBuilder` convenience view. Use
  `@WatchViewModel(spec)` for reactive spec-based resolution.

### Changed

- AutoDispose now observes handle disposal only. Owner paths, ViewModel
  listeners, binding-owned subscriptions, and dependency edges are no longer
  migrated between object generations.
- Obtain a distinct instance with a new explicit key, or globally `recycle` the
  old generation and let a resolver property call `watch/read(spec)` again.

## [0.4.2] - 2026-07-27

### Documentation

- Make stable `ViewModelSpec` plus `watch/read` the unambiguous default in the
  README, bundled skill, project guidance, examples, and public API comments.
- Separate cached lookup into an advanced-only section and document its cache
  miss, creation-order, identity, and cross-owner lifecycle coupling.
- Replace the UIKit `lazy var` example with a computed resolver property and
  make the sample counter binding-managed by default.

## [0.4.1] - 2026-07-27

### Fixed

- Require an explicit key for every `aliveForever` spec, including root
  bindings as well as ViewModel-to-ViewModel dependencies. Invalid
  configurations now fail fast before the builder runs, while the Store
  enforces the same rule for internal factories.

### Tests

- Add root, computed-key, and Store-boundary validation coverage while
  retaining serial execution with `swift test --no-parallel`.

## [0.4.0] - 2026-07-27

Aligns AppleViewModel's module-composition, dependency ownership, and instance
identity semantics with Flutter `view_model`.

### Changed

- VM-to-VM dependencies now resolve through a stable binding owned by each parent object generation. Unkeyed children retain identity while shared-parent root owners join or leave, and child lifetime cannot be shorter than the parent generation that owns it.
- Unkeyed specs now reuse one instance per resolved ViewModel type within a binding; different bindings remain isolated. Use explicit keys for cross-binding sharing or multiple same-type instances in one binding.
- Owner tracking is source-aware, so direct and parent-propagated paths with the same visible binding id can be released independently.
- Synchronous dependency propagation is transaction-based and updates each binding at most once in diamond graphs.
- `recycle(_:)` now finds and disposes the managed instance globally, including children owned only through a parent. Added `recreate(_:builder:)` to replace an object while preserving active owners.
- Align README, project guidance, and the bundled skill with Flutter `view_model` terminology: spec-first resolution, managed non-singleton modules by default, resolver properties, advanced cached lookup, and source-aware lifecycle controls.

### Safety

- Nested `aliveForever` dependencies must use an explicit key.
- Construction/recreation uses checked transactions; reset-invalidated replacements are disposed instead of being installed into a dead handle.

### Tests

- Add shared-parent handoff, multi-path ownership, global child recycle, watch/read bubbling, diamond de-duplication, recreation, retained-parent, and reset-during-recreate coverage.
- Require the suite to run serially with `swift test --no-parallel` because registry, configuration, lifecycle, and proxy state are process-global.

## [0.3.3] - 2026-05-11

### Changed

- **`viewModelBinding` resolution no longer uses `@TaskLocal`.** The previous mechanism wrapped construction in `ViewModelBinding.$current.withValue(self)` and relied on `@TaskLocal` propagation to surface the binding inside `init()` / `onCreate(_:)`. That made `viewModelBinding` access from `Task.detached`, old Combine sinks, UIKit target/action callbacks, and any other non-Task-inheriting context fragile during the construction window. The new mechanism:
  - injects the parent binding into the VM's `refHandler` via `addRef(...)` *inside* the builder closure, immediately after `factory.build()` returns and *before* `InstanceHandle.init` invokes `onCreate(_:)`. From `onCreate` onward `viewModelBinding` reads from `dependencyBindings` and is no longer sensitive to execution context;
  - replaces `@TaskLocal current` with a `@MainActor`-local stack pushed by `ViewModelBinding.withBuilding(_:_:)` for the duration of `factory.build()`. This is the only fallback path now, used solely while the VM's `init()` body is running.

### Removed

- **Breaking:** `ViewModelBinding.current` (the `@TaskLocal`) and the `_currentTaskLocal` SPI hook have been removed. Direct callers should migrate to `ViewModelBinding.currentBuilding` (SPI), but in practice no application code should be reading this — the binding is reachable through `viewModelBinding` from any point past the VM's `init()`.

### Tests

- Replace the TaskLocal-mechanism white-box test in `OnCreateBindingResolutionTests` with two cases: one that asserts `viewModelBinding` resolves correctly inside `onCreate`, and a new `Task.detached` regression that confirms a detached task spawned from `onCreate` still reaches the parent binding (the headline win of the new mechanism — TaskLocal would have lost the binding across the detach boundary).

## [0.3.2] - 2026-05-07

### Fixed

- **`ViewModel.onCreate(_:)` could not access `viewModelBinding`.** `InstanceHandle.init` invokes `onCreate` synchronously after the builder returns but before `AutoDisposeInstanceController` injects the parent binding via `refHandler.addRef(...)`. Previously the `ViewModelBinding.$current` TaskLocal scope only wrapped `factory.build()`, so by the time `onCreate` ran neither `dependencyBindings` nor the TaskLocal was available — any `viewModelBinding.read(...)` / `viewModelBinding.watch(...)` call in `onCreate` trapped with "No binding available". The fix moves the `withValue(self)` scope to wrap the entire `instanceController.getInstance(...)` call in `ViewModelBinding.createViewModel`, so dependency resolution from inside `onCreate` now works the same way it does from `init()`.

### Tests

- Add `OnCreateBindingResolutionTests` (8 cases) covering: `read` / `watch` from `onCreate`, TaskLocal mechanism verification, `init`/`onCreate` resolution parity, parent-dispose cascade, nested `onCreate` dependency chains, shared cached instance fires `onCreate` once, and registry visibility from sibling bindings.

## [0.3.1] - 2026-04-29

### Added

- Add SPDX license identifier (`Apache-2.0`) and copyright notice to `Package.swift` and module entry point.
- Add Swift Package Index (SPI) and release version badges to README.

### Changed

- Rename skills directory from `apple_view_model` to `apple-view-model`.

## [0.3.0] - 2026-04-29

Ships a listener-cleanup fix for `StateViewModelValueWatcher` and renames an internal parameter for clarity. Pure quality release — no API surface changes beyond the platform floor.

### Changed

- **`listen` → `observeRecreate`** parameter rename in `getInstancesByTag` (internal API). Call sites in `ViewModelBinding.watchCachesByTag` / `readCachesByTag` updated.

### Fixed

- **`StateViewModelValueWatcher`** now properly unregisters listener disposers in `deinit`. Previously, Swift 6's non-isolated `deinit` blocked access to `@MainActor` stored disposer closures, leaving orphaned listeners attached to the backing `StateViewModel` until it was itself disposed. Now uses `nonisolated(unsafe)` storage + a `Task { @MainActor }` cleanup in `deinit` so listeners are detached promptly.

### Notes

- The `OSAllocatedUnfairLock` is declared `nonisolated(unsafe) var` — the Swift 6 compiler flags mutable global state, but the lock itself is the synchronization mechanism. This is the same pattern recommended by the concurrency diagnostics ("disable concurrency-safety checks if accesses are protected by an external synchronization mechanism").
- Consumers pinning `from: "0.2.0"` in their `Package.swift` are unaffected; only callers with an explicit `.upToNextMinor(from: "0.2.0")` that also target sub-iOS-16 will see the version resolve to 0.3.0.

## [0.2.0] - 2026-04-19

Folds `ObservableViewModel` into the base `ViewModel` class. Every VM is now a first-class SwiftUI citizen — drop any `ViewModel` subclass into `@StateObject` or `@ObservedObject` without choosing a special base class.

### Changed

- **`ViewModel` now conforms to `ObservableObject`** directly. `notifyListeners()` automatically fires `objectWillChange.send()` so all VMs drive SwiftUI view updates out of the box.

### Removed

- **Breaking**: `ObservableViewModel` (and its deprecated alias `ChangeNotifierViewModel`) removed. Migration: replace `: ObservableViewModel` with `: ViewModel` — the base class now includes the `ObservableObject` conformance that `ObservableViewModel` previously provided.

## [0.1.0] - 2026-04-18

Initial release. Ported from the Flutter package [`view_model`](https://github.com/lwj1994/flutter_view_model).

### Added — Core

- **`ViewModel`** — base class with `listen` / `notifyListeners` / `update` / `addDispose` and lifecycle hooks (`onCreate`, `onBind`, `onUnbind`, `onDispose`).
- **`StateViewModel<State>`** — immutable state management via `setState` / `listenState` / `listenStateSelect`. Equality resolution: instance-level `equals` → global `config.equals` → reference identity.

### Added — Spec / Factory

- **`ViewModelSpec<T>`** — zero-argument factory declaration.
- **`ViewModelSpecWithArg1..4`** — 1–4 argument factories using `callAsFunction`.
- **`key` / `tag` / `aliveForever`** controls for sharing and lifecycle.
- **`setProxy` / `clearProxy`** for swapping builders in tests.

### Added — Registry

- **`InstanceManager` / `Store<T>` / `InstanceHandle` / `InstanceFactory`** — instance registry keyed by `ObjectIdentifier(T.self)` and `key`, with `bindingIds` reference counting.

### Added — Binding

- **`ViewModelBinding` + `HostedViewModelBinding`** — DI container supporting `watch` / `read` / `watchCached` / `readCached` / `maybeWatchCached` / `maybeReadCached`.
- **`ViewModelBindingHandler`** — internal dependency resolver (SPI-hidden).
- **`@TaskLocal static var current: ViewModelBinding?`** — Swift equivalent of Dart's Zone for VM-to-VM dependency injection. A VM's `viewModelBinding` property resolves to the binding that created it, enabling fully decoupled cross-module DI.

### Added — Pause / Resume

- **`PauseAwareController` + `BasePauseProvider`** — driven by `AsyncStream<Bool>`.
- **`AppPauseProvider`** — subscribes to `UIScene.willDeactivateNotification` / `didActivateNotification`.
- **`UIKitVisibilityPauseProvider`** — manual pause/resume for UIKit view/controller visibility.

### Added — SwiftUI

- **`@WatchViewModel(spec)` / `@ReadViewModel(spec)`** property wrappers.
- **`ViewModelBuilder(spec) { vm in … }` / `CachedViewModelBuilder`**.
- **`ObserverBuilder(value) { … }`** — convenience binding for `ObservableValue`.
- **`StateViewModelValueWatcher`** — fine-grained rebuild via `listenStateSelect`.

### Added — UIKit / NSObject

- **`NSObject.viewModelBinding`** — associated-object-backed `HostedViewModelBinding` that auto-disposes when the host is deallocated.
- **`ViewModelBindingRefreshable`** protocol — implement `viewModelBindingDidUpdate()` to receive refresh notifications.

### Added — Observable

- **`ObservableValue<T>` + `ObservableStateViewModel<T>`** — lightweight subscribable values backed by `StateViewModel` + `shareKey`. Two `ObservableValue` instances with the same `shareKey` read and write the same underlying state.

### Added — Configuration

- **`ViewModelConfig`** — `isLoggingEnabled` / global `equals` / global `onError`.
- **`ViewModelLifecycle`** — process-level lifecycle observer.
- **`ViewModel.initialize(config:lifecycles:)`** / `ViewModel.addLifecycle(_:)`.

### Added — Logging

- Built on `os.Logger` (`subsystem: "tech.echoing.AppleViewModel"`).
- `viewModelLog` / `reportViewModelError` are `nonisolated` — safe to call from any actor, background `Task`, or `@Sendable` callback.

### Tests

- 43 unit tests covering core VM, StateVM, binding watch/read, spec sharing, parameterized specs, dependency injection, lifecycle, pause/resume, ObservableValue, and NSObject binding.

### Platforms

- iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ / visionOS 1+.
- Swift 6.0+ with full language mode and strict concurrency. All public API is `@MainActor`.
