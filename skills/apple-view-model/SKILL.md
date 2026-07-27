---
name: apple-view-model
description: Use AppleViewModel in Swift 6 projects for state management, functional-module composition, dependency injection, automatic lifecycle, SwiftUI/UIKit bindings, ViewModel-to-ViewModel dependencies, sharing, pause/resume, and tests.
---

# AppleViewModel Skill

AppleViewModel is the Apple-platform port of Flutter `view_model`'s core model:
a type-keyed registry, binding-based source-aware ownership, functional modules
composed as ViewModels, and automatic disposal. Preserve that mental model while
adapting UI integration and error behavior to Swift.

## Source of truth

- Public API and examples: [repository README](../../README.md)
- Runtime behavior: `Sources/AppleViewModel/`
- Contract tests: `Tests/AppleViewModelTests/`
- Conceptual upstream: Flutter `view_model` README and skill

If this skill conflicts with the repository README or tests, follow the current
repository and update the skill.

## Trigger conditions

Use this skill when:

- Code imports `AppleViewModel` or uses `ViewModel`, `StateViewModel`,
  `ViewModelSpec`, `ViewModelBinding`, `@WatchViewModel`, or `@ReadViewModel`.
- The task concerns state, DI, module composition, lifecycle, sharing,
  pause/resume, SwiftUI/UIKit integration, or AppleViewModel tests.

## Primary resolution rule

- Use a stable, module-level `ViewModelSpec` and resolve it with `watch(spec)` or
  `read(spec)`. This is the default for UI hosts, plain bindings, tests, and
  ViewModel-to-ViewModel dependencies.
- `watch` creates/reuses, binds, observes handle recreation/disposal, and listens
  to the ViewModel's own notifications.
- `read` creates/reuses, binds, and observes handle recreation/disposal without
  listening to the ViewModel's own notifications.
- Cached APIs are advanced lookup-only escape hatches. They require an instance
  created by another path, cannot create a missing dependency, and should not be
  suggested as the normal DI style.

## Core model

- Any functional unit can be a ViewModel: UI state, service, repository,
  coordinator, cache, or domain capability.
- Prefer managed instances over global singletons. Default specs to no `key` and
  `aliveForever: false`; let the binding graph own creation and disposal.
- `ViewModel` is the light business/lifecycle base with `listen`,
  `notifyListeners`, `update`, `addDispose`, and `viewModelBinding`.
- `StateViewModel<State>` adds immutable state, `setState`, `previousState`,
  `listenState`, and `listenStateSelect`.
- `ViewModelSpec<VM>` is a factory declaration, not the instance itself.
- `ViewModelBinding` is the owner/container used by SwiftUI, UIKit, NSObject,
  plain Swift hosts, and tests.
- All public ViewModel and binding APIs are `@MainActor`.

## Identity, sharing, and retention

- Identity is the resolved ViewModel type plus the effective `key`. The
  builder's runtime result and `tag` do not participate in identity.
- With no explicit key, one binding reuses one instance per resolved ViewModel
  type and remains isolated from other bindings.
- Use a key for intentional cross-binding sharing or multiple instances of the
  same type in one binding.
- `tag` is only a grouping/lookup label.
- A key does not retain an instance.
- `aliveForever` only skips automatic disposal when ownership reaches zero.
  Explicit `recycle` and `InstanceManager.shared.debugReset()` still dispose it.
- Every `aliveForever` spec requires an explicit key, whether it is resolved by
  a root binding or another ViewModel. Swift fails fast before calling the
  builder when the key is missing or computes to `nil`; the Store enforces the
  same invariant for internal factories.

```swift
// Managed by one resolving binding by default.
let catalogSpec = ViewModelSpec<CatalogViewModel> { CatalogViewModel() }

// Explicit app-wide sharing and retention, only when required.
let sessionSpec = ViewModelSpec<SessionViewModel>(
    key: "app-session",
    aliveForever: true
) { SessionViewModel() }
```

Parameterized factories use `ViewModelSpecWithArg` and
`ViewModelSpecWithArg2...4`. Prefer a key derived from arguments when equal
arguments are intended to share.

## Choosing a binding

| Context | Recommended API | Lifecycle |
| --- | --- | --- |
| SwiftUI broad rebuild | `@WatchViewModel(spec)` | Binding host follows the view wrapper. |
| SwiftUI access without broad rebuild | `@ReadViewModel(spec)` | Bound, no VM-wide subscription. |
| SwiftUI selected fields | `@ReadViewModel` + `StateViewModelValueWatcher` | Selector owns fine-grained observation. |
| SwiftUI without wrapper | `ViewModelBuilder(spec) { ... }` | Child builder owns the binding. |
| UIKit / NSObject | computed property using `viewModelBinding.watch/read` | Associated binding follows the host. |
| Plain Swift / tests | `ViewModelBinding()` | Caller must call `dispose()`. |

Use a computed resolver property for UIKit/NSObject hosts when explicit global
`recycle` or recreation is possible:

```swift
@MainActor
final class OrdersController: UIViewController, ViewModelBindingRefreshable {
    private var orders: OrdersViewModel { viewModelBinding.watch(ordersSpec) }

    func viewModelBindingDidUpdate() {
        render(orders)
    }
}
```

## Binding API semantics

| API | Creates? | Owns on hit? | VM notifications | Handle recreate/dispose |
| --- | ---: | ---: | ---: | ---: |
| `watch(spec)` | Yes | Yes | Yes | Yes |
| `read(spec)` | Yes | Yes | No | Yes |
| `watchCached(key:/tag:)` | No | Yes | Yes | Yes |
| `readCached(key:/tag:)` | No | Yes | No | Yes |
| `maybeWatchCached` | No | Yes on hit | Yes | Yes |
| `maybeReadCached` | No | Yes on hit | No | Yes |
| `watchCachesByTag` | No, all hits | Yes | Yes | Yes |
| `readCachesByTag` | No, all hits | Yes | No | Yes |

Non-`maybe` single-result cached lookups throw on a miss. A single lookup by tag
can be ambiguous and depends on cache creation order; use the batch API when a
tag may match several instances.

`listen`, `listenState`, and `listenStateSelect` are binding-owned side effects.
They resolve through `read`, are removed on binding disposal, and migrate to a
replacement during `recreate`. Never place a `listen` call in a repeatedly
evaluated resolver property.

## ViewModel-to-ViewModel composition

Expose dependencies through computed resolver properties. Do not retain a
nested ViewModel in `lazy var`, a stored property, or an ad-hoc cache.

```swift
let cartSpec = ViewModelSpec<CartViewModel> { CartViewModel() }
let pricingSpec = ViewModelSpec<PricingViewModel> { PricingViewModel() }

@MainActor
final class CheckoutViewModel: ViewModel {
    var cart: CartViewModel { viewModelBinding.read(cartSpec) }
    var pricing: PricingViewModel { viewModelBinding.watch(pricingSpec) }
}
```

- A resolver declaration creates nothing until accessed.
- Use `read` to call a child without bubbling its own notifications.
- Use `watch` when a child update should call
  `parent.onDependencyNotify(child)` and then notify the parent.
- Every parent object generation lazily owns one stable dependency binding. It
  supplies a private child identity, keeps resolved children alive for at least
  the parent's lifetime, and mirrors current root owners in real time.
- Ownership is source-aware. Direct and multiple parent paths sharing one
  visible binding id are released independently.
- Synchronous propagation is transaction-based; each binding updates at most
  once even in a diamond graph.

## Lifecycle controls and safety

- Routine cleanup is binding-driven; do not call `vm.dispose()` directly.
- `recycle(vm)` is a destructive global escape hatch. It removes every owner
  path and force-disposes the managed object, including `aliveForever`.
- `recreate(vm, builder:)` replaces an object while preserving active owner
  relationships and binding-owned subscriptions.
- Always re-resolve through a computed property after either operation; a
  stored reference may point to a disposed generation.
- Recursive construction, runtime dependency cycles, and invalid nested
  `aliveForever` usage fail fast on the main actor. Recreation is checked so a
  reset-invalidated replacement is disposed rather than installed.

Lifecycle hooks are `onCreate`, `onBind`, `onUnbind`, and `onDispose`. Register
owned resources with `addDispose` and let the framework invoke cleanup.

## State and observation

- Choose `ViewModel` for commands/services or broad change events.
- Choose `StateViewModel<State>` for immutable state and state diffs; neither is
  universally preferred.
- `setState` is the only operation that emits a state diff. A plain
  `notifyListeners()` only reaches broad ViewModel listeners.
- Full-state equality is local initializer `equals` → global
  `ViewModelConfig.equals` → reference identity for class values; value types
  are treated as changed without a comparator.
- `listenStateSelect` requires an `Equatable` selected value and compares it
  with Swift equality. Unlike current Flutter `view_model`, it has no local
  selector-`equals` argument.
- Pair `StateViewModelValueWatcher` with `@ReadViewModel`, not
  `@WatchViewModel`, to avoid a duplicate broad subscription.

## Pause/resume and platform differences

- No pause provider is installed by default.
- Add `AppPauseProvider` for application visibility or
  `UIKitVisibilityPauseProvider` for UIKit page visibility.
- AppleViewModel additionally exposes `ObservableValue` / `ObserverBuilder`.
- This port currently has no Flutter DevTools extension, `@GenSpec` generator,
  scoped `overrideWith/runWithOverride`, route provider, or ticker provider.
- Swift public builders are non-throwing; invalid construction/dependency
  graphs therefore surface as fail-fast preconditions rather than Dart-style
  recoverable `ViewModelError`s at the public resolution boundary.

## Pitfalls to catch

1. Recommending a keyed `aliveForever` singleton for every service.
2. Caching a resolved ViewModel in `lazy var` or another long-lived field.
3. Assuming `read` is non-binding; it still owns the instance.
4. Using cached lookup as a replacement for a stable spec.
5. Calling `vm.dispose()` instead of relying on binding disposal or explicit
   global `recycle`.
6. Resolving any unkeyed `aliveForever` ViewModel, at root or nested scope.
7. Registering `listen` inside a computed property.
8. Pairing selector observation with a broad `watch` subscription.
9. Calling public APIs away from `@MainActor`.
10. Recreating specs inside SwiftUI `body`; keep specs module-level so identity
    intent and test proxies remain stable.

## Tests and mocks

- Tests must run single-threaded and in XCTest runner order because registry,
  config, lifecycle, reset, and spec-proxy state are process-global. Never use
  `swift test --parallel`, test sharding, or concurrent suites. Use
  `swift test --no-parallel`.
- Put constructor calls inside `ViewModelSpec` builders. Resolve managed
  instances through a test binding instead of constructing them directly.
- Do not retain ViewModels in test fields; use a resolver property backed by the
  binding when a shared fixture is necessary.
- Dispose every test binding.
- `XCTestCase.setUp()` is nonisolated; wrap global reset in
  `MainActor.assumeIsolated`.
- Use `setProxy` / `clearProxy` with `defer` for mocks.

```swift
final class MyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            InstanceManager.shared.debugReset()
            ViewModel.debugReset()
        }
    }

    @MainActor
    func test_example() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }

        let value = binding.read(featureSpec)
        // assertions
        _ = value
    }
}
```

## Verification and installation

```bash
swift build
swift test --no-parallel
```

Platforms: iOS 16+, macOS 13+, tvOS 16+, watchOS 9+, visionOS 1+;
Swift 6.0+.

```swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.4.1")
```
