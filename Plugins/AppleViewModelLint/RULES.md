# AppleViewModelLint rules

Good and bad examples for every rule reported by the `AppleViewModelLint` build
tool plugin. See [Recommended usage lint](../../README.md#recommended-usage-lint)
for setup. All findings are build warnings; they never fail the build. Rules with
an auto-fix are applied by the `AppleViewModelLintFix` command plugin; see
[Applying fixes](#applying-fixes).

| Rule ID | Catches |
| --- | --- |
| [`dependency-cycle`](#dependency-cycle) | ViewModels that resolve each other |
| [`cached-view-model`](#cached-view-model) | A resolved ViewModel kept in a stored or lazy property |
| [`alive-forever-key`](#alive-forever-key) | `aliveForever` without a key |
| [`unmanaged-construction`](#unmanaged-construction) | A ViewModel constructed outside a builder |

The checks are syntax-based. They see declarations in the target being built,
not in other modules.

## Shared declarations

The examples below use these declarations:

```swift
import AppleViewModel

struct CounterState: Equatable {
    var count = 0
}

@MainActor
final class CounterViewModel: StateViewModel<CounterState> {
    init() { super.init(state: CounterState()) }

    func increment() { setState(CounterState(count: state.count + 1)) }
}

@MainActor let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
```

Spec initializers are main-actor isolated, so a global spec is marked
`@MainActor`. In a target that uses default MainActor isolation, as new Xcode
app targets do, the attribute is optional.

## `dependency-cycle`

Two or more ViewModels resolve each other through their own
`viewModelBinding`. Resolving any of them can recurse until the runtime cycle
check stops it. The warning lists the cycle path, followed by a note for every
edge.

**Bad**

```swift
@MainActor let sessionSpec = ViewModelSpec<SessionViewModel> { SessionViewModel() }
@MainActor let cartSpec = ViewModelSpec<CartViewModel> { CartViewModel() }

final class SessionViewModel: ViewModel {
    var cart: CartViewModel { viewModelBinding.read(cartSpec) }
}

final class CartViewModel: ViewModel {
    var session: SessionViewModel { viewModelBinding.read(sessionSpec) }
}
```

**Good**

Keep dependencies pointing one way. Move state that both sides need into the
lower-level module.

```swift
@MainActor let sessionSpec = ViewModelSpec<SessionViewModel> { SessionViewModel() }
@MainActor let cartSpec = ViewModelSpec<CartViewModel> { CartViewModel() }

final class SessionViewModel: ViewModel {
    var userId: String?
}

final class CartViewModel: ViewModel {
    var session: SessionViewModel { viewModelBinding.read(sessionSpec) }
}
```

The check compares types. If keys make the instances distinct on purpose, the
warning is advisory and can be disabled for the target.

## `cached-view-model`

The result of `read`/`watch`, or a throwing variant, is saved in a stored or
`lazy` property, a global variable, or a property assignment. After `recycle`
or disposal, the property still points at the old, disposed generation.

Auto-fix: a stored or `lazy` property initialized by `read`/`watch` becomes a
computed property when its type is known from an annotation or the spec's
explicit generic argument. Throwing, observed, and assigned storage needs a
manual change.

**Bad**

```swift
final class CheckoutViewModel: ViewModel {
    lazy var counter = viewModelBinding.read(counterSpec)
}

@MainActor
final class CounterController {
    let binding = ViewModelBinding()
    var counter: CounterViewModel?

    func start() {
        counter = binding.watch(counterSpec)
    }

    func close() { binding.dispose() }
}
```

**Good**

Use a computed property that resolves on every access, or the SwiftUI
property wrappers. A local constant inside one method is fine.

```swift
import SwiftUI

final class CheckoutViewModel: ViewModel {
    var counter: CounterViewModel { viewModelBinding.read(counterSpec) }
}

@MainActor
final class CounterController {
    let binding = ViewModelBinding()
    var counter: CounterViewModel { binding.watch(counterSpec) }

    func start() {
        let counter = binding.watch(counterSpec)
        counter.increment()
    }

    func close() { binding.dispose() }
}

struct CounterView: View {
    @WatchViewModel(counterSpec) var counter: CounterViewModel

    var body: some View {
        Button("\(counter.state.count)") { counter.increment() }
    }
}
```

## `alive-forever-key`

`aliveForever: true` keeps an instance after its last owner leaves. Without a
key, nothing can find that instance again, and the runtime rejects it before
the builder runs. A single-expression constant closure counts as a literal
for parameterized specs.

Auto-fix: adds `key: "auth"` for `authSpec`, or `{ "userCache-\($0)" }` for a
parameterized spec.

**Bad**

```swift
final class AuthViewModel: ViewModel {}

final class UserViewModel: ViewModel {
    let userId: String
    init(userId: String) { self.userId = userId }
}

@MainActor let authSpec = ViewModelSpec<AuthViewModel>(aliveForever: true) { AuthViewModel() }

@MainActor let userCacheSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    aliveForever: { _ in true }
)
```

**Good**

```swift
final class AuthViewModel: ViewModel {}

final class UserViewModel: ViewModel {
    let userId: String
    init(userId: String) { self.userId = userId }
}

@MainActor let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

@MainActor let userCacheSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    key: { "user-\($0)" },
    aliveForever: { _ in true }
)
```

To share one instance between screens, a key alone is usually enough. The
instance is disposed after the last screen leaves, so `aliveForever` is not
needed.

## `unmanaged-construction`

A ViewModel type declared in the target is constructed outside a spec builder
or a `ViewModelFactory.build`/`buildThrowing` method. No binding owns it, so it
never gets lifecycle callbacks or automatic disposal.

**Bad**

```swift
@MainActor
func startCounter() {
    let counter = CounterViewModel()
    counter.increment()
}
```

**Good**

Construct the ViewModel in a spec builder, as `counterSpec` does, or in
`ViewModelFactory.build`, and resolve it through a binding. This also applies
in tests.

```swift
@MainActor
func startCounter() {
    let binding = ViewModelBinding()
    binding.read(counterSpec).increment()
    binding.dispose()
}

@MainActor
final class CounterFactory: ViewModelFactory {
    func build() -> CounterViewModel { CounterViewModel() }
}
```

## Applying fixes

```sh
swift package --allow-writing-to-package-directory apple-view-model-fix
```

Add `--target <name>` to limit the run. In Xcode, right-click the project in the
navigator and choose **AppleViewModelLintFix**. The plugin rewrites only what it
can prove safe, then prints the warnings that remain.

## Disabling a rule

Fix the ownership or spec problem first. To turn a rule off for every target
that uses the plugin, create `.apple-view-model-lint.json` beside
`Package.swift`, or in the Xcode project directory:

```json
{
  "disabledRules": ["cached-view-model"]
}
```

There is no per-line suppression. Unknown rule IDs fail the scan, so a typo
cannot silently disable a check. Run `swift package clean` (in Xcode,
**Product → Clean Build Folder**) after adding or deleting the file.
