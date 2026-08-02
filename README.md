# AppleViewModel

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flwj1994%2Fapple_view_model%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/lwj1994/apple_view_model)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flwj1994%2Fapple_view_model%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/lwj1994/apple_view_model)
[![](https://img.shields.io/github/v/release/lwj1994/apple_view_model?label=release)](https://github.com/lwj1994/apple_view_model/releases)

> 📖 Changelog: [CHANGELOG](./CHANGELOG.md) · Releases: [GitHub Releases](https://github.com/lwj1994/apple_view_model/releases)

**AppleViewModel is a state-management, functional-module composition, DI, and automatic-lifecycle framework** for Apple platforms, with first-class SwiftUI and UIKit integration.

Core idea: **anything can be a ViewModel** — business state, repositories, network services, utility stores, page controllers. Subclass `ViewModel`, declare a `ViewModelSpec`, and you get shared instances with automatic lifecycle management. VMs can depend on other VMs, giving you full DI across modules.

- **Managed module composition**: `ViewModelSpec` declares how to build and identify a module. Retrieve instances with `binding.watch(spec)` / `binding.read(spec)`. Inside a VM, expose dependencies through computed properties that resolve from `viewModelBinding`.
- **Automatic lifecycle**: Every host holds a `ViewModelBinding`. Reference counting drives disposal — when the last host releases its reference, the VM's `onDispose` fires. No manual cleanup.
- **Default UI integration**:
  - SwiftUI: `@WatchViewModel` / `@ReadViewModel` / typed `StateViewModelSelector` / compatibility `StateViewModelValueWatcher`. `ViewModel` is itself an `ObservableObject`.
  - UIKit: `NSObject.viewModelBinding` — works on `UIViewController`, `UIView`, or any `NSObject`. Associated-object lifetime auto-disposes the binding.
- **Platforms**: iOS 16+; macOS 13+; tvOS 16+; watchOS 9+; visionOS 1+. UIKit files are guarded with `#if canImport(UIKit)`.
- **Swift**: Requires Swift 6.0+, full language mode and strict concurrency. All public API is `@MainActor`.

### Version Compatibility

Deployment target: **iOS 16+**. Swift 6 language mode with strict concurrency (`@MainActor`, `Sendable`).

## Core resolution rules

> [!IMPORTANT]
> The default path is always **stable spec → `watch(spec)` / `read(spec)`**.
> A spec may contain a key or tag and should still be passed through these APIs;
> knowing cache identity is not a reason to bypass the spec.

- Use a stable, module-level `ViewModelSpec`, then resolve it with `watch(spec)` or `read(spec)`. These are the primary APIs for UI hosts, plain bindings, tests, and ViewModel-to-ViewModel dependencies.
- `watch` and `read` both create or reuse an instance, establish ownership, and observe handle disposal, including force-recycle. `watch` additionally listens to the ViewModel's own `notifyListeners()`.
- Prefer managed instances over global singletons. A feature, service, repository, coordinator, or domain capability should normally use an unkeyed spec with `aliveForever: false`; the binding graph then owns creation and disposal.
- Cached APIs are advanced, lookup-only escape hatches. They cannot create a missing instance and should not replace spec-based dependency resolution.
- Resolve ViewModels through computed properties rather than `lazy var` or stored references. This lets the next access observe an explicit recycle or an asynchronous lifecycle change.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.6.0")
```

Add `"AppleViewModel"` to your target dependencies.

### Claude Code Skill

This repo includes a Claude Code skill that provides AppleViewModel API reference for AI-assisted coding:

```bash
npx skills add https://github.com/lwj1994/apple_view_model --skill apple-view-model
```

Once installed, Claude Code automatically recognizes and uses AppleViewModel API patterns.

### Architecture Example

The bundled skill includes an English, multi-file
[Instagram architecture example](./skills/apple-view-model/examples/instagram_architecture/README.md).
It demonstrates API, repository, feature-state, and startup-coordinator
ViewModels composed through stable specs and computed dependency properties.
The example is intentionally excluded from the Swift Package target.

## The three pieces

AppleViewModel's DI model: **Service (ViewModel) + Registration (Spec) + Container (Binding)**.

### 1. ViewModel — the service

Pick a base class:

| Base class | Use case |
|---|---|
| `ViewModel` | Lightest option. Has `listen` / `notifyListeners` / `update`. Good for pure services (Repository, Network, Cache, etc.) |
| `StateViewModel<State>` | Manages immutable state with `setState` / `listenState` / `listenStateSelect` |

Both are `ObservableObject`, so they slot directly into SwiftUI `@StateObject`.

```swift
struct CounterState: Equatable {
    var count: Int = 0
    var label: String = ""
}

@MainActor
final class CounterViewModel: StateViewModel<CounterState> {
    init() { super.init(state: CounterState()) }

    func increment() {
        setState(CounterState(count: state.count + 1, label: state.label))
    }
}
```

Any shared dependency — AuthService, ThemeStore, Logger — works the same way. Subclass `ViewModel`, register a spec.

### 2. ViewModelSpec — the registration

Declare how the VM is built and whether instances are shared. Specs are typically module-level constants:

```swift
// Plain spec: one instance of this VM type per binding (private to each host)
let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }

// Intentional app-wide service: same key → same instance across all bindings.
// aliveForever skips automatic disposal at zero owners, but recycle/reset still dispose it.
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// Parameterized spec: different key per argument, same-argument instances shared
let userSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    key: { "user-\($0)" }
)
// Usage: binding.watch(userSpec("abc"))
```

Specs support scoped `overrideWith` / `runWithOverride` for tests. Nested and
out-of-order restore are safe, and overlapping async `runWithOverride` bodies
are task-local. `setProxy` / `clearProxy` remain as the legacy global fallback.

When a factory can fail, use `throwingBuilder` with the recoverable binding API:

```swift
let profileSpec = ViewModelSpec<ProfileViewModel>(throwingBuilder: {
    try ProfileViewModel.load()
})

let profile = try binding.readThrowing(profileSpec)
```

Normal `watch` / `read` remain fail-fast for source compatibility.

Identity is the resolved ViewModel type plus its effective key. An unkeyed spec receives a private key from the resolving binding, so the same type is reused within that binding and isolated from other bindings. Use an explicit `key` only for intentional cross-binding sharing or multiple instances of the same type in one binding. `tag` is a grouping/lookup label and does not participate in identity. A key does not retain an instance; `aliveForever` only skips automatic disposal when its owner set becomes empty.

### 3. ViewModelBinding — the container

Any scope that uses VMs holds a binding — it is the DI container for that scope.

#### SwiftUI

```swift
struct CounterView: View {
    @WatchViewModel(counterSpec) var vm: CounterViewModel
    var body: some View {
        Button("\(vm.state.count)") { vm.increment() }
    }
}
```

`@ReadViewModel` binds without subscribing (no rebuild on changes). Keep the
spec and use these property wrappers directly for normal SwiftUI resolution.

#### UIKit

```swift
final class MyViewController: UIViewController, ViewModelBindingRefreshable {
    private var vm: CounterViewModel { viewModelBinding.watch(counterSpec) }

    func viewModelBindingDidUpdate() {
        label.text = "\(vm.state.count)"
    }
}
```

`viewModelBinding` is on `NSObject`, so `UIView` and custom `NSObject` subclasses work too:

```swift
final class CounterView: UIView, ViewModelBindingRefreshable {
    private var vm: CounterViewModel { viewModelBinding.watch(counterSpec) }

    func viewModelBindingDidUpdate() {
        setNeedsLayout()
    }
}
```

#### Plain Swift / Tests

```swift
let binding = ViewModelBinding()
let vm = binding.watch(counterSpec)
vm.increment()
binding.dispose()  // reference count drops → VM auto-disposed
```

## VM-to-VM DI

The core value of a DI framework is one ViewModel injecting another. Every managed parent object generation lazily owns a stable dependency binding. It gives unkeyed children a parent-private identity, keeps resolved children alive for at least the parent's lifetime, and mirrors the parent's current root owners to those children in real time.

Expose dependencies through computed properties. Do not retain a nested ViewModel in `lazy var`, a stored property, or an ad-hoc cache: after explicit `recycle` or an asynchronous lifecycle race, the next property access must be able to resolve the current object generation.

```swift
// Module A: export a managed capability. It is not global by default.
let sessionSpec = ViewModelSpec<SessionViewModel> { SessionViewModel() }
let cartSpec = ViewModelSpec<CartViewModel> { CartViewModel() }

// Module B: inject it
@MainActor
final class OrderViewModel: ViewModel {
    var session: SessionViewModel { viewModelBinding.read(sessionSpec) } // call without bubbling
    var cart: CartViewModel { viewModelBinding.watch(cartSpec) }  // watch: child updates notify this parent
}
```

Modules A, B, C develop independently, each exporting their own specs. Getter declarations create nothing until accessed. Reference counting handles disposal: a child cannot die before a parent generation that owns it, but it can outlive that parent when another direct or parent path still owns it.

A keyed parent can be shared by several roots. When roots join or leave, its already-resolved children keep the same identity and receive source-aware owner updates. A root may own the same keyed child both directly and through one or more parents; releasing one path cannot remove the others. Synchronous notification propagation is transaction-based, so a diamond graph refreshes each binding at most once.

Unkeyed identity is the resolved ViewModel type plus the current binding's private default key: repeated resolution of the same type reuses one instance within that binding, while different bindings remain isolated. Add an explicit key for cross-binding sharing or multiple instances of the same type in one binding. Every `aliveForever` spec must have an explicit key, whether resolved by a root binding or another ViewModel; a missing or computed-nil key fails fast before the builder runs, and the Store enforces the same invariant for internal factories.

## Binding access APIs

### Primary: spec-based resolution (recommended)

Normal application code should keep a stable spec and use one of these APIs:

| API | Creates if absent? | Establishes ownership? | VM `notifyListeners()` | Handle disposal |
|---|---:|---:|---:|---:|
| `watch(spec)` | Yes | Yes | Yes | Yes |
| `read(spec)` | Yes | Yes | No | Yes |

Choose `watch` when ViewModel notifications should update the owner. Choose
`read` for lifecycle-bound access without subscribing to those notifications.
Use `watchThrowing` / `readThrowing` when builder failures, dependency-cycle
validation, or reset conflicts must be handled as recoverable errors; ordinary
`watch` / `read` intentionally fail fast for those failures.

### Advanced: cached lookup

> [!CAUTION]
> Do not use cached lookup as a substitute for spec-based dependency
> resolution. It reaches into an instance that another path must already have
> created, couples the caller to cache identity, creation order, and another
> owner's lifecycle, and cannot create a missing dependency. Use it only for an
> intentional cross-owner query of an existing cache entry.

| API | Creates if absent? | Establishes ownership? | VM `notifyListeners()` | Handle disposal |
|---|---:|---:|---:|---:|
| `watchCached(key:/tag:)` | No | Yes | Yes | Yes |
| `readCached(key:/tag:)` | No | Yes | No | Yes |
| `maybeWatchCached(key:/tag:)` | No; returns `nil` | Yes on hit | Yes | Yes |
| `maybeReadCached(key:/tag:)` | No; returns `nil` | Yes on hit | No | Yes |
| `watchCachesByTag(_:)` | No; returns all hits | Yes | Yes | Yes |
| `readCachesByTag(_:)` | No; returns all hits | Yes | No | Yes |

Single-result non-`maybe` lookups throw on a miss, and tag lookup can be
ambiguous when several instances share a tag. The source-compatible non-throwing
`maybe*` APIs return `nil` on lookup failure. Use `maybeWatchCachedThrowing`,
`maybeReadCachedThrowing`, or `ViewModel.maybeReadCachedThrowing` when unexpected
non-`ViewModelError` failures must be preserved. If the caller has a spec—even a
keyed or tagged spec—use `watch(spec)` / `read(spec)` instead.

`listen`, `listenState`, and `listenStateSelect` use `read` internally and automatically remove their side-effect subscriptions when the binding disposes. Do not put a `listen` call in a repeatedly evaluated resolver property.

## Lifecycle controls and ownership

- `recycle(vm)` is a destructive global escape hatch: it removes every direct and parent owner path and disposes the shared object, including an `aliveForever` object. The next resolver-property access creates a fresh instance.
- `aliveForever` requires an explicit key at every resolution site and skips automatic disposal when ownership reaches zero; it does not prevent explicit `recycle` or `ViewModel.reset()`.
- `ViewModel.reset()` force-disposes every cached generation (including retained instances), rejects reentrant creation while teardown is running, clears global configuration and lifecycle observers, and permits clean re-initialization.
- Direct and parent-propagated paths are source-aware. `onBind` runs for the first source of a visible binding id, and `onUnbind` for the last source.

There is no in-place instance replacement API. To obtain an independent instance, use a new explicit key. If replacing the shared cached generation globally is intentional, call `recycle(vm)` and let resolver properties call `watch(spec)` / `read(spec)` again. The cache miss creates a new handle and dependency tree; owner paths, watch/listen subscriptions, and dependency edges are not migrated from the disposed object.

Construction and dependency graphs are checked. Recursive construction, runtime ownership cycles, and every unkeyed `aliveForever` spec fail fast on the main actor. Failed builders roll back the dependency scope they started.

## Fine-grained observation

```swift
@ReadViewModel(userSpec) var vm: UserViewModel

StateViewModelSelector(
    viewModel: vm,
    selector: { $0.name }
) { name in
    Text(name)
}
```

Only the strongly typed selected value triggers a rebuild. Pass `equals` when
that selection needs a local comparison rule. Equality priority is local
selector `equals` → global `ViewModelConfig.equals` → Swift `Equatable`.

`StateViewModelValueWatcher` remains available for a list of untyped selectors.
Both selector views rebuild their subscriptions when the ViewModel generation
changes. Pair either one with `@ReadViewModel`, so `watch` does not add a broad
duplicate rebuild. Full-state equality remains local initializer `equals` →
global `ViewModelConfig.equals` → reference identity for class values.

## Pause / Resume

No provider is active by default. Add `AppPauseProvider` to pause update delivery while the app is in the background:

```swift
let binding = ViewModelBinding()
binding.addPauseProvider(AppPauseProvider())
```

While paused, `notifyListeners` calls accumulate; on resume, a single `onUpdate` flushes them.

For UIKit page visibility, use `UIKitVisibilityPauseProvider` and call `pause()` / `resume()` from `viewWillDisappear` / `viewWillAppear`.

## Configuration

```swift
@main
struct MyApp: App {
    init() {
        ViewModel.initialize(
            config: ViewModelConfig(
                isLoggingEnabled: true,
                equals: { ($0 as? AnyHashable) == ($1 as? AnyHashable) },
                onError: { error, type in
                    // e.g. Crashlytics.crashlytics().record(error: error)
                }
            ),
            lifecycles: [DebugLifecycleLogger()]
        )
    }
    var body: some Scene { /* ... */ }
}
```

`onError` may throw; the framework catches that secondary failure and logs it
together with the original callback error so notification/disposal can continue.

## Testing

Tests must run single-threaded and in XCTest runner order:

```bash
swift test --no-parallel
```

Do not enable `--parallel`, test sharding, or concurrent suites. The registry,
global configuration, lifecycle observers, and spec proxies are mutable
process-global state that tests reset between cases.

```swift
func test_with_mock() {
    let restore = counterSpec.overrideWith(
        ViewModelSpec { MockCounterViewModel() }
    )
    defer { restore() }

    let binding = ViewModelBinding()
    let vm = binding.watch(counterSpec)
    XCTAssertTrue(vm is MockCounterViewModel)
    binding.dispose()
}
```

Keep constructor calls inside specs and resolve test instances through a `ViewModelBinding`; do not construct a managed ViewModel directly in a test body or retain one in a long-lived test property. Dispose the binding with `defer` so lifecycle behavior remains part of the test:

```swift
@MainActor
func test_counter() {
    let binding = ViewModelBinding()
    defer { binding.dispose() }

    let counter = binding.read(counterSpec)
    counter.increment()
    XCTAssertEqual(counter.state.count, 1)
}
```

Reset global state between tests:

```swift
override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
        ViewModel.reset()
    }
}
```

## License

Apache-2.0. See `LICENSE`.
