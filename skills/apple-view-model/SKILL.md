---
name: apple-view-model
description: Triggered when using AppleViewModel (a component-level ViewModel DI framework for iOS/macOS/tvOS/watchOS/visionOS) in Swift 6 projects. Covers ViewModel / StateViewModel base classes, ViewModelSpec factory declarations, SwiftUI bindings (@WatchViewModel / @ReadViewModel / ViewModelBuilder / ObserverBuilder), UIKit bindings (NSObject.viewModelBinding), VM-to-VM DI, pause/resume, and test mock patterns.
---

# AppleViewModel Skill

Full API reference: [README](./README.md)

## Trigger Conditions

Activate when:
- User code contains `import AppleViewModel`, `ViewModelSpec`, `@WatchViewModel`, `@ReadViewModel`, `StateViewModel`, `ViewModelBinding`
- User asks about DI, ViewModel lifecycle, shared services, or component architecture on Apple platforms
- User encounters build errors or runtime issues involving this framework

## Guiding Users

### Choosing a base class

Ask what the class needs to do, then recommend:

| Need | Recommend | Reason |
| --- | --- | --- |
| Emit "I changed" events | `ViewModel` | Lightest: `listen`, `notifyListeners`, `update {}` |
| Manage immutable state | `StateViewModel<State>` | Adds `setState`, `listenState`, `listenStateSelect`, equality checks |
| Pure service (Auth, Cache, Network) | `ViewModel` | Doesn't hold UI state, just notifies when ready/changed |

Both conform to `ObservableObject`. `StateViewModel` is preferred for new SwiftUI code.

### Choosing a binding approach

| Context | Recommend | Notes |
| --- | --- | --- |
| SwiftUI, needs rebuild on change | `@WatchViewModel(spec)` | Subscribes to VM changes |
| SwiftUI, service-only, no rebuild | `@ReadViewModel(spec)` | Creates + binds, skips subscription |
| SwiftUI, fine-grained field watch | `StateViewModelValueWatcher` | Only rebuilds when selected fields change |
| SwiftUI, no property wrapper | `ViewModelBuilder(spec) { vm in ... }` | Wraps child content |
| UIKit (UIViewController / UIView) | `viewModelBinding.watch(spec)` | On `NSObject`, conform to `ViewModelBindingRefreshable` |
| Plain Swift / tests | `ViewModelBinding()` directly | Call `dispose()` when done |

### Choosing a spec type

| Scenario | Spec type |
| --- | --- |
| No params, no sharing | `ViewModelSpec<T> { T() }` |
| No params, shared globally | `ViewModelSpec<T>(key: "k", aliveForever: true) { T() }` |
| Same args → same instance | `ViewModelSpecWithArg1<T, A>(builder:key:)` |
| 1–4 arguments | `ViewModelSpecWithArg1` through `WithArg4` |

### watch vs read (quick reference)

- `watch` = create + bind + subscribe (rebuilds on change)
- `read` = create + bind, no subscribe
- `*Cached` variants skip creation (throw on miss); `maybe*Cached` return nil on miss

## Common Patterns to Suggest

### Service registration (cross-module DI)

When user has a service that multiple modules need (Auth, API client, Theme):

```swift
// Export from the service module
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// Consume in any other module
@MainActor
final class OrderViewModel: ViewModel {
    lazy var auth = viewModelBinding.read(authSpec)
}
```

- Always suggest `lazy var` for VM-to-VM dependencies to avoid init-order issues
- Use `read` unless the parent needs rebuild when the dependency changes

### App initialization

When user is setting up the framework in their App entry point:

```swift
@main struct MyApp: App {
    init() {
        ViewModel.initialize(
            config: ViewModelConfig(isLoggingEnabled: true, onError: { error, type in ... }),
            lifecycles: [])
    }
}
```

### Background pause support

When user wants to suppress UI updates while app is backgrounded:

```swift
binding.addPauseProvider(AppPauseProvider())
```

## Pitfalls to Catch

When reviewing or debugging user code, check for:

1. **`viewModelBinding` accessed in `init`** — `@TaskLocal` only resolves during `factory.build()`. Fix: use `lazy var`.
2. **Missing `@MainActor`** — all VMs and bindings must be main-actor-isolated.
3. **Recreating specs in View bodies** — should be module-level `let`; otherwise `setProxy` test hooks break.
4. **Calling `vm.dispose()` directly** — framework manages lifecycle; use `binding.recycle(vm)` to force-destroy.
5. **`XCTestCase.setUp` is nonisolated** — wrap global reset in `MainActor.assumeIsolated { ... }`.
6. **`setState` with partial state** — must pass the full new state value, not a mutation.
7. **State not `Equatable`** without a global `equals` — identical states may trigger unnecessary rebuilds.

## Test Guidance

Standard test skeleton to suggest:

```swift
final class MyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            InstanceManager.shared.debugReset()
            ViewModel.debugReset()
        }
    }

    @MainActor func test_example() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        // test code
    }
}
```

Mock pattern:

```swift
spec.setProxy(ViewModelSpec { MockVM() })
defer { spec.clearProxy() }
```

## Platform

iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ / visionOS 1+. Swift 6.0+.

## Installation

```swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.3.0")
```
