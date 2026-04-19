# AppleViewModel

> 📖 更新历史请看 [CHANGELOG](./CHANGELOG.md) · 下载页：[GitHub Releases](https://github.com/lwj1994/apple_view_model/releases)

**AppleViewModel 本质上是一个 DI（依赖注入）框架**，为 Apple 平台提供组件级依赖管理能力，默认无缝集成 SwiftUI 与 UIKit。从 Flutter 包 [`view_model`](https://github.com/lwj1994/flutter_view_model) 移植而来。

核心理念：**任何东西都可以写成 `ViewModel` 的形式**——业务状态、Repository、网络服务、工具 Store、页面控制器……只要继承 `ViewModel` 并通过 `ViewModelSpec` 注册，就能跨模块互相复用、互相引用、互相 DI。

- **Service 注册式 DI**：用 `ViewModelSpec` 声明 "怎么建 / 按什么 key 共享 / 要不要永驻"，通过 `binding.watch(spec)` / `binding.read(spec)` 获取实例；VM 内部还能用 `viewModelBinding.watch(otherSpec)` 拿到别的 VM，天然支持 VM-to-VM 依赖。
- **生命周期自动化**：每个宿主对应一个 `ViewModelBinding`，内部按引用计数管理实例——宿主释放时自动 `dispose`，无需手写清理代码。
- **默认双端 UI 集成**：
  - SwiftUI：`@WatchViewModel` / `@ReadViewModel` / `ViewModelBuilder` / `ObserverBuilder` / `StateViewModelValueWatcher`；`ViewModel` 本身就是 `ObservableObject`，可直接塞进 `@StateObject`。
  - UIKit / AppKit 风格对象图：`NSObject.viewModelBinding`，`UIViewController` / `UIView` / 自定义 `NSObject` 宿主都可直接用，关联对象在宿主释放时自动 dispose。
- **平台**：iOS 16+ 为主要目标；Core 不依赖 UIKit，macOS / tvOS / watchOS / visionOS 已在 `Package.swift` 里预留，UIKit 相关文件用 `#if canImport(UIKit)` 自动裁剪。
- **Swift**：要求 Swift 6.0+，全包启用 Swift 6 language mode 和严格并发。所有对外 API 统一 `@MainActor`。

## 安装

Swift Package Manager：

```swift
.package(path: "../apple_view_model")
// 或
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.1.0")
```

在 target 里加依赖 `"AppleViewModel"`。

## 三件套

AppleViewModel 的 DI 模型是：**Service（ViewModel）+ 注册声明（Spec）+ 容器宿主（Binding）**。只要理解这三件套，就能把任何东西接进来当作可注入的服务使用。

### 1. ViewModel —— Service 本体

继承二选一。无论哪个都是 `ObservableObject`，可直接塞进 SwiftUI `@StateObject`：

| 基类 | 用途 |
| --- | --- |
| `ViewModel` | 最轻量，拿 `listen` / `notifyListeners` / `update` 就够了；也适合做纯服务（Repository / Network / Cache 等） |
| `StateViewModel<State>` | 管理不可变 state，附带 `setState` / `listenState` / `listenStateSelect` |

> 💡 任何你想跨模块共享的东西——AuthService、ThemeStore、页面 ViewModel、甚至一个全局 Logger——都可以写成 `ViewModel` 子类，然后像服务一样注册。

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

### 2. ViewModelSpec —— Service 注册

把 VM 当服务注册到系统里——告诉框架**怎么建、按什么 key 共享、要不要永驻**。Spec 通常写成模块级 `let`，就是这个服务的"地址":

```swift
// 普通 spec：默认每个 binding 新建一份
let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }

// 全局共享服务：相同 key 的 spec 在任何 binding 都拿同一实例；aliveForever 表示进程内常驻
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// 带参数的 spec：按参数 key 区分实例，同参数共享
let userSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userId: $0) },
    key: { "user-\($0)" }
)
// 使用：binding.watch(userSpec("abc"))
```

Spec 还支持 `setProxy` / `clearProxy`——测试时把注册实现临时换成 mock。

### 3. ViewModelBinding —— 容器 / 宿主

任何"想用 VM 的地方"都持有一个 binding，它就是这次作用域里的 DI 容器。SwiftUI 和 UIKit 都有现成的桥，你也可以手动创建一个用于纯 Swift / 测试。

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
| `ChangeNotifier` + `Listenable` | `ViewModel`（自带 `ObservableObject`） | Combine 驱动 SwiftUI |
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

## VM-to-VM 依赖：模块间互相注入

DI 框架最核心的能力——**一个 ViewModel 里注入另一个 ViewModel**。继承 `ViewModel` 就自带 `viewModelBinding`，内部用 `@TaskLocal` 解析到"创建它的那个 binding"。所以只要对方已经按 spec 注册过，这里就能直接拿到它。

```swift
// 模块 A 注册一个服务
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }

// 模块 B 注册业务 VM，里面注入模块 A 的服务
@MainActor
final class OrderViewModel: ViewModel {
    // read：只用不订阅刷新；watch：订阅，别人变了我 notify
    lazy var auth: AuthViewModel = viewModelBinding.read(authSpec)
    lazy var cart: CartViewModel = viewModelBinding.watch(cartSpec)
}
```

这样模块 A / B / C 可以各自独立开发、各自 export 自己的 spec；使用方在最外层的 binding 里拼装即可。引用计数自动管理生命周期：父 binding dispose → 通过它创建的 VM 若没有别的引用，也一起 dispose。

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
