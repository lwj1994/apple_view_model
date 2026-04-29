# Changelog

All notable changes to AppleViewModel will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

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
