# AppleViewModel

从 Flutter 包 [`view_model`](https://github.com/lwj1994/flutter_view_model) 移植而来的 Apple 平台组件级 ViewModel 框架。基于 `@TaskLocal` 做 DI、基于引用计数做生命周期、基于 `@StateObject` / `objectWillChange` 桥到 SwiftUI。

- **平台**：当前为 iOS 16+。Core 不依赖 UIKit，macOS / tvOS / watchOS / visionOS 已在 `Package.swift` 里预留，UIKit 相关文件用 `#if canImport(UIKit)` 自动裁剪。
- **Swift**：要求 Swift 6.0+，全包启用 Swift 6 language mode 和严格并发。
- **UI 集成**：SwiftUI（`@WatchViewModel` / `@ReadViewModel` / `ViewModelBuilder` / `ObserverBuilder` / `StateViewModelValueWatcher`）+ Objective-C 对象宿主（`NSObject.viewModelBinding`，`UIViewController` / `UIView` 等都可直接用）。

## 安装

Swift Package Manager：

```swift
.package(path: "../apple_view_model")
// 或
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.1.0")
```

在 target 里加依赖 `"AppleViewModel"`。

## 三件套

### 1. ViewModel

业务 ViewModel 继承三选一：

| 基类 | 用途 |
| --- | --- |
| `ViewModel` | 最轻量，拿 `listen` / `notifyListeners` / `update` 就够了 |
| `StateViewModel<State>` | 管理不可变 state，附带 `setState` / `listenState` / `listenStateSelect` |
| `ObservableViewModel` | 同时是 `ObservableObject`，可直接塞进 `@StateObject`（原 `ChangeNotifierViewModel` 已 typealias 保留向后兼容） |

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

### 2. Spec

工厂声明——告诉系统怎么建、怎么共享：

```swift
// 普通 spec
let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }

// 全局共享，永不销毁
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// 带参数；相同参数共享同一实例
let userSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    key: { "user-\($0)" }
)
// 使用：binding.watch(userSpec("abc"))
```

### 3. Binding

任何"想用 VM 的地方"都是 binding。SwiftUI 和 UIKit 都有现成的桥。

#### SwiftUI

```swift
struct CounterView: View {
    @WatchViewModel(counterSpec) var vm: CounterViewModel
    var body: some View {
        Button("\(vm.state.count)") { vm.increment() }
    }
}
```

`@ReadViewModel` 是"只绑定不订阅"版本；`ViewModelBuilder(spec) { vm in ... }` 可以避免写 property wrapper。

#### UIKit

```swift
final class MyVC: UIViewController, ViewModelBindingRefreshable {
    private lazy var vm = viewModelBinding.watch(counterSpec)

    func viewModelBindingDidUpdate() {
        // 比如刷新 UI
        label.text = "\(vm.state.count)"
    }
}
```

`viewModelBinding` 是挂在 `NSObject` 上的关联对象，宿主释放时会自动 dispose，所以 `UIViewController`、`UIView`、自定义 `NSObject` 宿主都能直接复用这一套：

```swift
final class CounterView: UIView, ViewModelBindingRefreshable {
    private lazy var vm = viewModelBinding.watch(counterSpec)

    func viewModelBindingDidUpdate() {
        setNeedsLayout()
    }
}
```

#### 纯 Swift / 测试

```swift
let binding = ViewModelBinding()
let vm = binding.watch(counterSpec)
vm.increment()
// ...
binding.dispose()  // 引用计数归零，VM 自动销毁
```

## 核心机制对照表（Dart → Swift）

| Dart 版 | Swift 版 | 说明 |
| --- | --- | --- |
| `mixin ViewModel` | `open class ViewModel` | Swift 没 mixin，改用继承；仍可组合多个 protocol 实现 |
| `mixin class ViewModelBinding` | `open class ViewModelBinding` | 子类化替代 mixin |
| `StateViewModel<T>` | `StateViewModel<State>` | `setState` 的相等判断优先级：实例级 equals > 全局 config.equals > 引用相等（类对象） |
| `ChangeNotifier` + `Listenable` | `ObservableViewModel` + `ObservableObject` | Combine 驱动 SwiftUI |
| `ViewModelFactory` / `ViewModelSpec.arg…` | `ViewModelFactory` / `ViewModelSpecWithArg1..4` | arg 版本用 `callAsFunction` 应用参数 |
| `InstanceManager` / `Store<T>` / `InstanceHandle` | 同名 | 按 `ObjectIdentifier(T.self)` 分桶；handle 维护 `bindingIds` 列表 |
| Zone-based DI | `@TaskLocal static var current: ViewModelBinding?` | VM 构造期通过 `ViewModelBinding.$current.withValue(self)` 提供上下文 |
| `WidgetViewModelBinding` | `HostedViewModelBinding` | 带一个 `refresh` 闭包，UI 层用它触发重绘 |
| `ViewModelStateMixin` | `@WatchViewModel` / `@ReadViewModel` (`DynamicProperty`) | 内部用 `@StateObject` 托管 binding |
| `ViewModelBuilder` / `CachedViewModelBuilder` | 同名 SwiftUI `View` | 不想写 property wrapper 时用 |
| `UIViewController.viewModelBinding` / `NSObject.viewModelBinding` | Objective-C host API | 在 `UIViewController`、`UIView`、`NSViewController` 风格对象上托管 VM，用关联对象自动清理生命周期 |
| `ObservableValue` + `ObserverBuilder` | 同名 | 底层仍是 `StateViewModel<T>` + `shareKey` |
| `StateViewModelValueWatcher` | 同名 | 基于 `listenStateSelect` 的细粒度重建 |
| `PauseAwareController` + `PauseProvider` | 同名 | `AsyncStream<Bool>` 替代 `StreamController<bool>` |
| `AppPauseProvider` (Flutter lifecycle) | `AppPauseProvider` (UIScene) | 订阅 `UIScene.willDeactivateNotification` / `didActivateNotification` |
| `ViewModelLifecycle` / `ViewModelConfig` / `ViewModelError` / `ErrorType` | 同名 | 行为对齐 |
| DevTools 扩展 / `view_model_generator` | **未移植** | iOS 侧未来可用 Xcode Instruments / Swift Macros 补上 |

## 配置

```swift
@main
struct MyApp: App {
    init() {
        ViewModel.initialize(
            config: ViewModelConfig(
                isLoggingEnabled: true,
                equals: { ($0 as? AnyHashable) == ($1 as? AnyHashable) },
                onError: { error, type in
                    Crashlytics.record(error: error, category: "\(type)")
                }
            ),
            lifecycles: [DebugLifecycleLogger()]
        )
    }
    var body: some Scene { /* ... */ }
}
```

## watch vs read

| | 创建 (没有就新建) | 绑定 (引用计数 +1) | 监听变更 (触发刷新) |
| --- | :-: | :-: | :-: |
| `watch(spec)` | ✓ | ✓ | ✓ |
| `read(spec)` | ✓ | ✓ | ✗ |
| `watchCached(key:)` | ✗ | ✓ | ✓ |
| `readCached(key:)` | ✗ | ✓ | ✗ |

所有 `*Cached` 变体找不到就抛错；对应的 `maybe*Cached` 返回 nil。

## VM 内部访问其它 VM

继承 `ViewModel` 就自带 `viewModelBinding`，内部用 `@TaskLocal` 解析到父 binding。

```swift
@MainActor
final class OrderViewModel: ViewModel {
    lazy var auth: AuthViewModel = viewModelBinding.read(authSpec)
    lazy var cart: CartViewModel = viewModelBinding.watch(cartSpec)
}
```

父 binding dispose → 通过它创建的 VM 若没有别的引用，也一起 dispose。

## 细粒度重建

```swift
StateViewModelValueWatcher(
    viewModel: vm,
    selectors: [\.name, \.age]
) { state in
    Text("\(state.name), age \(state.age)")
}
```

只有 `name` 或 `age` 变化时才重新运行 builder；`vm.state` 中其它字段的改动不会触发重绘。

## Pause / Resume

默认不开启任何 provider。`AppPauseProvider` 接到 UIScene 变化：

```swift
let binding = ViewModelBinding()
binding.addPauseProvider(AppPauseProvider())
```

paused 期间 `notifyListeners` 会累积但不转发到 `onUpdate`；resume 时合并触发一次。

## 测试

```swift
func test_with_mock() {
    // 临时替换 builder
    counterSpec.setProxy(ViewModelSpec { MockCounterViewModel() })
    defer { counterSpec.clearProxy() }

    let binding = ViewModelBinding()
    let vm = binding.watch(counterSpec)
    XCTAssertTrue(vm is MockCounterViewModel)
    binding.dispose()
}
```

跨测试隔离：

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

Apache-2.0，详见 `LICENSE`。
# apple_view_model
