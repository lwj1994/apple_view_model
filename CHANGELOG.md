# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-04-29

### Changed

- **Breaking**: Raise minimum deployment targets to iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+.
- Replace `NSLock` with `OSAllocatedUnfairLock` in `ViewModelGlobalConfig`.
- Rename `listen` parameter to `observeRecreate` in `getInstancesByTag`.

### Fixed

- `StateViewModelValueWatcher` now properly unregisters listener disposers in `deinit`.

## [0.2.0] - 2026-04-19

### Changed

- `ViewModel` now conforms to `ObservableObject` directly — `notifyListeners()` automatically triggers `objectWillChange.send()`. All VMs can be used with SwiftUI `@StateObject` / `@ObservedObject` out of the box.

### Removed

- **Breaking**: Remove `ObservableViewModel` base class (and its deprecated alias `ChangeNotifierViewModel`). The functionality has been folded into `ViewModel`. Migration: replace `: ObservableViewModel` with `: ViewModel`.

## [0.1.0] - 2026-04-18

Initial release. Ported from the Flutter package [`view_model`](https://github.com/lwj1994/flutter_view_model).

### Added

- **Core**
  - `ViewModel` — base class with `listen` / `notifyListeners` / `update` / `addDispose` and lifecycle hooks (`onCreate`, `onBind`, `onUnbind`, `onDispose`).
  - `StateViewModel<State>` — immutable state management via `setState` / `listenState` / `listenStateSelect`. Equality resolution: instance-level `equals` → global `config.equals` → reference identity.
- **Spec / Factory**
  - `ViewModelSpec<T>` — zero-argument factory declaration.
  - `ViewModelSpecWithArg1..4` — 1–4 argument factories using `callAsFunction`.
  - `key` / `tag` / `aliveForever` controls for sharing and lifecycle.
  - `setProxy` / `clearProxy` for swapping builders in tests.
- **Registry**
  - `InstanceManager` / `Store<T>` / `InstanceHandle` / `InstanceFactory` — instance registry keyed by `ObjectIdentifier(T.self)` and `key`, with `bindingIds` reference counting.
- **Binding**
  - `ViewModelBinding` + `HostedViewModelBinding` — DI container supporting `watch` / `read` / `watchCached` / `readCached` / `maybeWatchCached` / `maybeReadCached`.
  - `ViewModelBindingHandler` — internal dependency resolver (SPI-hidden).
  - `@TaskLocal static var current: ViewModelBinding?` — Swift equivalent of Dart's Zone for VM-to-VM dependency injection.
- **Pause / Resume**
  - `PauseAwareController` + `BasePauseProvider` (driven by `AsyncStream<Bool>`).
  - `AppPauseProvider` — subscribes to `UIScene.willDeactivateNotification` / `didActivateNotification`.
  - `UIKitVisibilityPauseProvider` — manual pause/resume for UIKit view/controller visibility.
- **SwiftUI**
  - `@WatchViewModel(spec)` / `@ReadViewModel(spec)` property wrappers.
  - `ViewModelBuilder(spec) { vm in … }` / `CachedViewModelBuilder`.
  - `ObserverBuilder(value) { … }` — convenience binding for `ObservableValue`.
  - `StateViewModelValueWatcher` — fine-grained rebuild via `listenStateSelect`.
- **UIKit / NSObject**
  - `NSObject.viewModelBinding` — associated-object-backed `HostedViewModelBinding` that auto-disposes when the host is deallocated.
  - `ViewModelBindingRefreshable` protocol — implement `viewModelBindingDidUpdate()` to receive refresh notifications.
- **Observable**
  - `ObservableValue<T>` + `ObservableStateViewModel<T>` — lightweight subscribable values backed by `StateViewModel` + `shareKey`.
- **Configuration**
  - `ViewModelConfig` — `isLoggingEnabled` / global `equals` / global `onError`.
  - `ViewModelLifecycle` — process-level lifecycle observer.
  - `ViewModel.initialize(config:lifecycles:)` / `ViewModel.addLifecycle(_:)`.
- **Logging**
  - Built on `os.Logger` (`subsystem: "tech.echoing.AppleViewModel"`).
  - `viewModelLog` / `reportViewModelError` are `nonisolated` — safe to call from any actor, background `Task`, or `@Sendable` callback. Global config protected by `NSLock`.
- **Tests**
  - 40+ unit tests covering core VM, StateVM, binding watch/read, spec sharing, parameterized specs, dependency injection, lifecycle, pause/resume, and ObservableValue.
- **Platforms**
  - iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ / visionOS 1+.
  - Swift 6.0+ with strict concurrency enabled.
