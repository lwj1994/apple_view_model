---
name: apple-view-model
description: Use AppleViewModel in Swift 6 projects for state management, functional-module composition, dependency injection, automatic ViewModel and Task lifecycles, SwiftUI/UIKit bindings, ViewModel-to-ViewModel dependencies, sharing, pause/resume, and tests.
---

# AppleViewModel Skill

AppleViewModel is the Apple-platform port of Flutter `view_model`'s core model:
a type-keyed registry, binding-based source-aware ownership, functional modules
composed as ViewModels, and automatic disposal. Preserve that mental model while
adapting UI integration and error behavior to Swift.

## Source of truth

- Public API and examples: [repository README](../../README.md)
- Dependency version: latest stable [GitHub Release](https://github.com/lwj1994/apple_view_model/releases)
- Runtime behavior: `Sources/AppleViewModel/`
- Contract tests: `Tests/AppleViewModelTests/`
- Skill-local sharing example: `examples/sharing_example.swift`
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
  ViewModel-owned Tasks, concurrency, pause/resume, SwiftUI/UIKit integration,
  or AppleViewModel tests.

## Resolution decision order (must follow)

1. Keep a stable, module-level `ViewModelSpec`. Do this for UI hosts, plain
   bindings, tests, and ViewModel-to-ViewModel dependencies.
2. Resolve that spec with `watch(spec)` when ViewModel notifications should
   update the owner, or `read(spec)` when lifecycle-bound access should not
   listen to the ViewModel's own notifications. Both APIs create/reuse, bind,
   and observe handle disposal, including force-recycle.
   Never pass the resolved ViewModel instance to another view, controller,
   coordinator, or ViewModel. Pass ordinary data or the spec and its identity
   arguments; the receiving owner must resolve through its own binding so its
   ownership and lifecycle are represented in the binding graph.
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
  `notifyListeners`, `update`, `addDispose`, `taskScope`, and
  `viewModelBinding`.
- `StateViewModel<State>` adds immutable state, `setState`, `previousState`,
  `listenState`, and `listenStateSelect`.
- `ViewModelSpec<VM>` is a factory declaration, not the instance itself.
- `ViewModelBinding` is the owner/container used by SwiftUI, UIKit, NSObject,
  plain Swift hosts, and tests.
- ViewModel, binding, lifecycle, and registry APIs are `@MainActor`.
  `ViewModel.config`, `viewModelLog`, and `reportViewModelError` are explicit
  thread-safe `nonisolated` exceptions.

## Main-actor concurrency policy

Treat `@MainActor` as a deliberate architecture boundary, not a limitation to
remove during implementation or refactoring. ViewModel state, the binding
graph, reference counts, notification delivery, and lifecycle transitions form
one UI-facing state machine. Normal application state management does not need
parallel mutation, and keeping that state machine single-threaded avoids locks,
atomics, cross-actor synchronization, and unnecessary `Sendable` propagation.
The resulting ordering is deterministic, application integration is simpler,
and both the framework and consuming code are easier to maintain.

When work genuinely benefits from another executor:

- Keep ViewModel access and state mutation on `@MainActor`.
- Copy the required input into immutable `Sendable` values before crossing the
  actor boundary. Do not capture a ViewModel, binding, or mutable state object
  in background work.
- Use `Task.detached`, a dedicated actor, or a `nonisolated` service for
  CPU-heavy or executor-bound work, then `await` its `Sendable` result and apply
  that result on `@MainActor`. Put legacy blocking APIs on a dedicated thread or
  queue instead of Swift's cooperative executor.
- Remember that `Task {}` created from `@MainActor` inherits the main actor. It
  is useful for structured asynchronous orchestration, but does not itself move
  CPU work to a background executor.
- Await ordinary asynchronous I/O directly when appropriate; actor suspension
  does not block the main thread.

## ViewModel-owned Task scope

Treat the lazy `taskScope` as the default creation path for unstructured work
whose result or side effects belong to one ViewModel generation.

- One `ViewModelTaskScope` is owned by each object generation. It is disposed
  synchronously from `ViewModel.onDispose`, not inferred from object `deinit`.
- `task(...)` creates a main-actor Task for async I/O, listener loops, and state
  application. `detachedTask(...)` creates a nonisolated CPU worker and accepts
  only `Sendable` captures/results; never capture a ViewModel or binding there.
- Both APIs return the Task handle. Completed Tasks unregister automatically,
  preventing finished handles from accumulating in long-lived ViewModels.
- `cancelAll()` cancels current work without disposing the scope, so the same
  ViewModel can start fresh listeners after a data-source or session rebind.

```swift
taskScope.task { [weak self] in
    let result = try await loadResult()
    try Task.checkCancellation()
    self?.setState(result)
}
```

Lifecycle rules:

- Zero-owner disposal cancels active Tasks for ordinary managed ViewModels.
- `recycle` and `ViewModel.reset()` cancel them for every ViewModel, including
  `aliveForever`; after disposal, any newly created scope Task is cancelled
  immediately.
- An `aliveForever` ViewModel skips zero-owner disposal, so its Tasks continue
  until `cancelAll()`, recycle, or reset.

Swift cancellation is cooperative. Task bodies should reach cancellation-aware
`await` points, call `Task.checkCancellation()`, or inspect
`Task.isCancelled` before applying results. Prefer `[weak self]`: logical
ViewModel disposal does not require Swift `deinit`, but a strong Task capture
can extend the disposed object's memory lifetime. Use SwiftUI `.task` for
View-owned work; use raw `Task {}` inside a ViewModel only when its lifetime is
intentionally independent from that ViewModel.

## Identity, sharing, and retention

- Identity is the resolved ViewModel type plus the effective `key`. The
  builder's runtime result and `tag` do not participate in identity.
- With no explicit key, one binding reuses one instance per resolved ViewModel
  type and remains isolated from other bindings.
- Use a key for intentional cross-binding sharing or multiple instances of the
  same type in one binding.
- For temporary sharing across sibling pages or independent bindings, let every
  participant resolve the same keyed spec with `watch/read`. Their bindings
  collectively define the local lifetime; the instance auto-disposes after the
  final participant unbinds.
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

Always use a computed resolver property for UIKit/NSObject hosts:

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
- In SwiftUI, use `@WatchViewModel` or `@ReadViewModel` directly. Configure
  parameterized specs in the view initializer. The wrappers resolve on access
  and manage binding ownership, observation, and disposal; no forwarding getter
  or custom binding host is needed. For UIKit and ViewModel dependencies, use
  computed resolver properties that call `viewModelBinding.watch/read(spec)`.
- Preserve spec-based resolution in refactors and migrations. Never introduce a
  cached API merely because a key or tag is available.
- Show cached lookup only when the user explicitly needs an already-created
  cross-owner cache entry, and state that absence, creation order, tag
  multiplicity, and the other owner's lifecycle are part of the contract.
- Default ordinary modules to an unkeyed spec with `aliveForever: false`; add a
  key or retention only when sharing or retention is intentional.
- Prefer keyed, binding-scoped sharing over `aliveForever` when the instance
  only needs to live while one or more participating pages are alive.
- Preserve the `@MainActor` boundary. If an operation needs background
  execution, isolate only its `Sendable` workload and return the result to the
  ViewModel instead of making ViewModel or binding state concurrent.
- Bind every ViewModel-owned unstructured Task with
  `taskScope.task` / `taskScope.detachedTask`, and make it cooperate with
  cancellation before applying results.

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
- `read` owns the child without forwarding its state notifications.
- `watch` still forwards child notification → parent notification → refresh
  request for bindings watching the parent. It is not an alias for `read`.
  A root that only reads the parent does not subscribe merely by owning it.
- Use explicit `listen` / `listenState` / `listenStateSelect` for
  business reactions, registered once in `onCreate` or another controlled
  initialization path, never in a computed property.
- Binding-owned `listen` uses `read`: the callback alone does not automatically
  notify the parent. Use `update` / `setState` explicitly when it changes parent
  state. A forwarded broad notification does not synthesize a parent state diff.
- Every parent object generation lazily owns one stable dependency binding. It
  supplies a private child identity, keeps resolved children alive for at least
  the parent's lifetime, and mirrors current root owners in real time.
- Ownership is source-aware. Direct and multiple parent paths sharing one
  visible binding id are released independently.
- Synchronous propagation is transaction-based; each binding updates at most
  once even in a diamond graph. Keep business computations in explicit
  dependency listeners rather than binding refresh callbacks.

For example, register a business reaction to a stable child spec:

```swift
@MainActor
final class CartAuditViewModel: ViewModel {
    private(set) var changeCount = 0

    override func onCreate(_ arg: InstanceArg) {
        super.onCreate(arg)
        viewModelBinding.listen(cartSpec) { [weak self] in
            guard let self else { return }
            self.update { self.changeCount += 1 }
        }
    }
}
```

The binding removes that subscription when the child handle or the parent
scope is disposed. Explicitly recycling the child does not migrate a business
listener to its replacement; register again through a controlled setup path
when following a new generation is required.

## Local scope: sharing one instance across pages

A common case is for page A to display data and page B to edit it. Page A must
see B's changes when B closes; if both pages are alive, A should react to the
changes immediately. Prefer the same spec with an explicit key and default
auto-disposal. Do not set `aliveForever: true` merely to share across pages:

```swift
@MainActor
final class DraftViewModel: ViewModel {
    let documentID: String
    private(set) var title = ""

    init(documentID: String) {
        self.documentID = documentID
        super.init()
    }

    func updateTitle(_ value: String) {
        update { title = value }
    }
}

let draftViewModelSpec = ViewModelSpecWithArg<DraftViewModel, String>(
    builder: { DraftViewModel(documentID: $0) },
    key: { "draft-\($0)" }
)

struct PageA: View {
    let documentID: String
    @WatchViewModel private var draft: DraftViewModel

    init(documentID: String) {
        self.documentID = documentID
        _draft = WatchViewModel(draftViewModelSpec(documentID))
    }

    var body: some View {
        VStack {
            Text(draft.title)
            NavigationLink("Edit") { PageB(documentID: documentID) }
        }
    }
}

struct PageB: View {
    @WatchViewModel private var draft: DraftViewModel

    init(documentID: String) {
        _draft = WatchViewModel(draftViewModelSpec(documentID))
    }

    var body: some View {
        TextField(
            "Title",
            text: Binding(
                get: { draft.title },
                set: { draft.updateTitle($0) }
            )
        )
    }
}
```

- A and B resolve the same instance because they use the same resolved
  ViewModel type and key. There is no need to use a cached API to retrieve an
  instance created by the other page.
- Both `watch(spec)` and `read(spec)` bind the instance to the current page. Use
  `watch` when the page must react to VM notifications; use `read` when it only
  invokes methods.
- While A and B both exist, each hosted binding owns the instance. Releasing B
  removes only B's bind, so A keeps the instance alive. When A is also released,
  the final bind is removed and the instance is automatically reclaimed.
- A `key` defines shared identity; it does not retain the instance forever. If
  multiple edit flows can coexist, include a document or session ID in the key
  to prevent unrelated flows from sharing state.
- The resulting lifetime is the union of all participating page scopes. This
  is usually more appropriate than `aliveForever: true`. Use `aliveForever`
  with an explicit key only when the instance must survive with zero bindings.

See `examples/sharing_example.swift` for the complete example.

## Lifecycle controls and safety

- Routine cleanup is binding-driven; do not call `vm.dispose()` directly.
- `recycle(vm)` is a destructive global escape hatch. It removes every owner
  path and force-disposes the managed object, including `aliveForever`.
- There is no in-place replacement capability. Use a new explicit key for an
  independent instance. If global replacement is intentional, call `recycle`
  and let getter-based `watch(spec)` / `read(spec)` create a new handle and
  dependency tree on the next access; do not migrate old relationships.
- After `recycle`, access the SwiftUI wrapper or computed resolver property
  again; a separately stored reference points to the disposed generation.
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
9. Calling ViewModel, binding, lifecycle, or registry APIs away from
   `@MainActor`.
10. Assuming `Task {}` created on `@MainActor` is background execution, or
    capturing a ViewModel/binding inside `Task.detached`.
11. Starting ViewModel-owned unstructured work outside `taskScope`, or ignoring
    cooperative cancellation before publishing its result.
12. Creating specs inside SwiftUI `body`; keep specs module-level so identity
    intent and test proxies remain stable.
13. Assuming `watch` does not forward child notifications or refresh bindings.

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

        var value: FeatureViewModel { binding.read(featureSpec) }
        // assertions
        _ = value
    }
}
```

## Verification and dependency installation

```bash
swift build
swift test --no-parallel
```

Platforms: iOS 16+, macOS 13+, tvOS 16+, watchOS 9+, visionOS 1+;
Swift 6.0+.

Before adding or updating the package dependency, query GitHub Releases and use
the newest non-draft, non-prerelease tag. Prefer
`gh release view --repo lwj1994/apple_view_model --json tagName,isDraft,isPrerelease`;
fall back to the Releases page when `gh` is unavailable. Never infer the version
from the default branch, a stale README example, or local tags.

At the time this skill was authored, the latest stable release is `0.7.0`:

```swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.7.0")
```
