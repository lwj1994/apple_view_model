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
- Architecture example: `examples/instagram_architecture/README.md` — a
  multi-file Instagram-style app composed from API, repository, user, feed,
  post-detail, comment, and startup-coordinator ViewModels.
- Conceptual upstream: Flutter `view_model` README and skill

If this skill conflicts with the repository README or tests, follow the current
repository and update the skill.

## Trigger conditions

Use this skill when:

- Code imports `AppleViewModel` or uses `ViewModel`, `StateViewModel`,
  `ViewModelSpec`, `ViewModelBinding`, `@WatchViewModel`, or `@ReadViewModel`.
- The task concerns state, DI, module composition, lifecycle, sharing,
  pause/resume, SwiftUI/UIKit integration, or AppleViewModel tests.

## Resolution decision order (must follow)

1. Keep a stable, module-level `ViewModelSpec`. Do this for UI hosts, plain
   bindings, tests, and ViewModel-to-ViewModel dependencies.
2. Resolve that spec with `watch(spec)` when ViewModel notifications should
   update the owner, or `read(spec)` when lifecycle-bound access should not
   listen to the ViewModel's own notifications. Both APIs create/reuse, bind,
   and observe handle disposal, including force-recycle.
3. Use `watchThrowing` / `readThrowing` with a spec `throwingBuilder` when the
   caller must recover from builder, cycle-validation, or reset-conflict errors.
   Ordinary `watch` / `read` intentionally remain fail-fast.
4. Use a cached API only when the task explicitly requires an advanced
   cross-owner query of an instance already created elsewhere. Cached APIs
   cannot create a missing dependency and must not be suggested as normal DI.

A key or tag on a spec does not change this order. Pass the keyed/tagged spec to
`watch` or `read`; knowing cache identity is not a reason to bypass the spec.

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
  Explicit `recycle` and `ViewModel.reset()` still dispose it.
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
| SwiftUI selected fields | `@ReadViewModel` + `StateViewModelSelector` | Strongly typed selector owns fine-grained observation. |
| UIKit / NSObject | computed property using `viewModelBinding.watch/read` | Associated binding follows the host. |
| Plain Swift / tests | `ViewModelBinding()` | Caller must call `dispose()`. |

Use a computed resolver property for UIKit/NSObject hosts when explicit global
`recycle` is possible:

```swift
@MainActor
final class OrdersController: UIViewController, ViewModelBindingRefreshable {
    private var orders: OrdersViewModel { viewModelBinding.watch(ordersSpec) }

    func viewModelBindingDidUpdate() {
        render(orders)
    }
}
```

## Primary binding APIs (recommended)

| API | Creates? | Owns on hit? | VM notifications | Handle disposal |
| --- | ---: | ---: | ---: | ---: |
| `watch(spec)` | Yes | Yes | Yes | Yes |
| `read(spec)` | Yes | Yes | No | Yes |

`watchThrowing(spec)` / `readThrowing(spec)` preserve the same ownership and
notification semantics while surfacing recoverable factory/cycle/reset errors.
Declare a fallible factory with `ViewModelSpec(throwingBuilder:)`. Do not replace
ordinary resolution with the throwing form when no recovery path is needed.

## Cached lookup APIs (advanced)

Do not replace a stable spec with cache lookup. These APIs couple the caller to
another path's creation order, cache identity, and lifecycle, and cannot create
a missing dependency. Show them only for an intentional query of existing
cross-owner state.

| API | Creates? | Owns on hit? | VM notifications | Handle disposal |
| --- | ---: | ---: | ---: | ---: |
| `watchCached(key:/tag:)` | No | Yes | Yes | Yes |
| `readCached(key:/tag:)` | No | Yes | No | Yes |
| `maybeWatchCached` | No | Yes on hit | Yes | Yes |
| `maybeReadCached` | No | Yes on hit | No | Yes |
| `watchCachesByTag` | No, all hits | Yes | Yes | Yes |
| `readCachesByTag` | No, all hits | Yes | No | Yes |

Non-`maybe` single-result cached lookups throw on a miss. A single lookup by tag
can be ambiguous and depends on cache creation order; use the batch API when a
tag may match several instances. The source-compatible non-throwing
`maybeWatchCached` / `maybeReadCached` APIs return `nil` on lookup failure. Use
their `*Throwing` counterparts when unexpected non-`ViewModelError` failures
must be preserved.

`listen`, `listenState`, and `listenStateSelect` are binding-owned side effects.
They resolve through `read` and are removed when the target handle or binding is
disposed. They are never migrated to another object. Never place a `listen` call
in a repeatedly evaluated resolver property.

## Response pattern for implementation requests

- Default every normal resolution example to a stable spec plus `watch(spec)`
  or `read(spec)`.
- Preserve spec-based resolution in refactors and migrations. Never introduce a
  cached API merely because a key or tag is available.
- Show cached lookup only when the user explicitly needs an already-created
  cross-owner cache entry, and state that absence, creation order, tag
  multiplicity, and the other owner's lifecycle are part of the contract.
- Default ordinary modules to an unkeyed spec with `aliveForever: false`; add a
  key or retention only when sharing or retention is intentional.

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
- There is no in-place replacement capability. Use a new explicit key for an
  independent instance. If global replacement is intentional, call `recycle`
  and let getter-based `watch(spec)` / `read(spec)` create a new handle and
  dependency tree on the next access; do not migrate old relationships.
- Always re-resolve through a computed property after `recycle`; a stored
  reference points to the disposed generation.
- Recursive construction, runtime dependency cycles, and invalid nested
  `aliveForever` usage fail fast through `watch/read`, or throw through
  `watchThrowing/readThrowing`. Failed builders roll back the dependency scope
  they started.
- `ViewModel.reset()` force-disposes all cached generations, including retained
  instances, blocks reentrant resolution during teardown, clears configuration
  and lifecycle observers, and allows initialization again.

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
- `listenStateSelect` requires an `Equatable` selected value. Comparison order
  is local selector `equals` → global `ViewModelConfig.equals` → Swift equality.
- Prefer the strongly typed `StateViewModelSelector`; keep
  `StateViewModelValueWatcher` only for compatibility with multiple untyped
  selectors. Both rebuild subscriptions when the VM generation changes.
- Pair either selector view with `@ReadViewModel`, not `@WatchViewModel`, to
  avoid a duplicate broad subscription.

## Pause/resume and platform differences

- No pause provider is installed by default.
- Add `AppPauseProvider` for application visibility or
  `UIKitVisibilityPauseProvider` for UIKit page visibility.
- This port currently has no Flutter DevTools extension, `@GenSpec` generator,
  route provider, or ticker provider.
- Swift retains fail-fast `watch/read` for source compatibility and additionally
  exposes throwing builders plus recoverable `watchThrowing/readThrowing`.

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
10. Creating specs inside SwiftUI `body`; keep specs module-level so identity
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
- Prefer `overrideWith` (idempotent restore) or async task-local
  `runWithOverride` for mocks. Keep `setProxy` / `clearProxy` only for legacy
  global override compatibility.

```swift
final class MyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            ViewModel.reset()
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
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.6.0")
```
