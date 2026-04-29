# AppleViewModel

> 📖 Changelog: [CHANGELOG](./CHANGELOG.md) · Releases: [GitHub Releases](https://github.com/lwj1994/apple_view_model/releases)

**AppleViewModel is a service-registry DI framework** for Apple platforms, with first-class SwiftUI and UIKit integration.

Core idea: **anything can be a ViewModel** — business state, repositories, network services, utility stores, page controllers. Subclass `ViewModel`, declare a `ViewModelSpec`, and you get shared instances with automatic lifecycle management. VMs can depend on other VMs, giving you full DI across modules.

- **Service-style DI**: `ViewModelSpec` declares how to build, whether to share (by key), and whether to keep alive. Retrieve instances with `binding.watch(spec)` / `binding.read(spec)`. Inside a VM, use `viewModelBinding.watch(otherSpec)` for VM-to-VM dependencies.
- **Automatic lifecycle**: Every host holds a `ViewModelBinding`. Reference counting drives disposal — when the last host releases its reference, the VM's `onDispose` fires. No manual cleanup.
- **Default UI integration**:
  - SwiftUI: `@WatchViewModel` / `@ReadViewModel` / `ViewModelBuilder` / `ObserverBuilder` / `StateViewModelValueWatcher`. `ViewModel` is itself an `ObservableObject`.
  - UIKit: `NSObject.viewModelBinding` — works on `UIViewController`, `UIView`, or any `NSObject`. Associated-object lifetime auto-disposes the binding.
- **Platforms**: iOS 16+; macOS 13+; tvOS 16+; watchOS 9+; visionOS 1+. UIKit files are guarded with `#if canImport(UIKit)`.
- **Swift**: Requires Swift 6.0+, full language mode and strict concurrency. All public API is `@MainActor`.

### Version Compatibility

Deployment target: **iOS 16+**. Swift 6 language mode with strict concurrency (`@MainActor`, `Sendable`).

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.3.0")
```

Add `"AppleViewModel"` to your target dependencies.

### Claude Code Skill

This repo includes a Claude Code skill that provides AppleViewModel API reference for AI-assisted coding:

```bash
npx skills add https://github.com/lwj1994/apple_view_model --skill apple-view-model
```

Once installed, Claude Code automatically recognizes and uses AppleViewModel API patterns.

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
// Plain spec: one instance per binding (private to each host)
let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }

// Shared service: same key → same instance across all bindings. aliveForever keeps it alive permanently.
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// Parameterized spec: different key per argument, same-argument instances shared
let userSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    key: { "user-\($0)" }
)
// Usage: binding.watch(userSpec("abc"))
```

Specs support `setProxy` / `clearProxy` for swapping implementations in tests.

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

`@ReadViewModel` binds without subscribing (no rebuild on changes). `ViewModelBuilder(spec) { vm in ... }` avoids writing a property wrapper.

#### UIKit

```swift
final class MyViewController: UIViewController, ViewModelBindingRefreshable {
    private lazy var vm = viewModelBinding.watch(counterSpec)

    func viewModelBindingDidUpdate() {
        label.text = "\(vm.state.count)"
    }
}
```

`viewModelBinding` is on `NSObject`, so `UIView` and custom `NSObject` subclasses work too:

```swift
final class CounterView: UIView, ViewModelBindingRefreshable {
    private lazy var vm = viewModelBinding.watch(counterSpec)

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

The core value of a DI framework: one ViewModel injecting another. Inherit `ViewModel` and you get `viewModelBinding`, which resolves to the binding that created this VM via `@TaskLocal`.

```swift
// Module A: register a service
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// Module B: inject it
@MainActor
final class OrderViewModel: ViewModel {
    lazy var auth: AuthViewModel = viewModelBinding.read(authSpec)   // read: use but don't subscribe
    lazy var cart: CartViewModel = viewModelBinding.watch(cartSpec)  // watch: subscribe to changes
}
```

Modules A, B, C develop independently, each exporting their own specs. The top-level binding wires them together. Reference counting handles disposal: when the parent binding disposes, VMs created through it drop their refs.

## watch vs read

| | Create (if missing) | Bind (ref +1) | Listen (triggers refresh) |
|---|---|---|---|
| `watch(spec)` | ✓ | ✓ | ✓ |
| `read(spec)` | ✓ | ✓ | ✗ |
| `watchCached(key:)` | ✗ | ✓ | ✓ |
| `readCached(key:)` | ✗ | ✓ | ✗ |

All `*Cached` variants throw on miss; `maybe*Cached` variants return nil.

## Fine-grained observation

```swift
@ReadViewModel(userSpec) var vm: UserViewModel

StateViewModelValueWatcher(
    viewModel: vm,
    selectors: [\.name, \.age]
) { state in
    Text("\(state.name), age \(state.age)")
}
```

Only `name` or `age` changes trigger a rebuild; other fields in `state` are ignored.

## ObservableValue

For lightweight cross-component state that doesn't need a full ViewModel:

```swift
let isDarkMode = ObservableValue<Bool>(initialValue: false, shareKey: "theme-dark")

ObserverBuilder(observable: isDarkMode) { dark in
    Image(systemName: dark ? "moon.fill" : "sun.max.fill")
}
```

Two `ObservableValue` instances with the same `shareKey` read and write the same underlying state.

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

## Testing

```swift
func test_with_mock() {
    counterSpec.setProxy(ViewModelSpec { MockCounterViewModel() })
    defer { counterSpec.clearProxy() }

    let binding = ViewModelBinding()
    let vm = binding.watch(counterSpec)
    XCTAssertTrue(vm is MockCounterViewModel)
    binding.dispose()
}
```

Reset global state between tests:

```swift
override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
        InstanceManager.shared.debugReset()
        ViewModel.debugReset()
    }
}
```

## License

Apache-2.0. See `LICENSE`.
