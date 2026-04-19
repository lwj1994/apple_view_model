---
name: apple-view-model
description: 在 Swift 6 项目里使用 AppleViewModel（iOS / macOS / tvOS / watchOS / visionOS 的组件级 ViewModel 框架）时触发。涵盖 ViewModel / StateViewModel 两件套（ViewModel 本身就是 ObservableObject）、ViewModelSpec 工厂声明、SwiftUI 绑定（@WatchViewModel / @ReadViewModel / ViewModelBuilder / ObserverBuilder）、UIKit 绑定（NSObject.viewModelBinding）、VM-to-VM 依赖、Pause/Resume、以及测试 mock 写法。
---

# AppleViewModel Skill

[lwj1994/apple_view_model](https://github.com/lwj1994/apple_view_model)：**Apple 平台的 DI（依赖注入）框架**，默认集成 SwiftUI + UIKit，Swift 6 严格并发。从 Flutter `view_model` 移植。

**核心思想**：任何东西（业务状态、Repository、网络服务、全局 Store 等）都可以写成 `ViewModel` 形式，通过 `ViewModelSpec` 以 **Service 注册**的方式声明，然后在模块之间互相复用、引用、互相注入。宿主生命周期 + 引用计数自动管理销毁——不用写 `dispose` 样板。

## 何时使用本 skill

- 代码里出现 `import AppleViewModel` 或 `ViewModelSpec` / `@WatchViewModel` / `StateViewModel`
- 用户问 "AppleViewModel 怎么写 XXX" / "怎么在 SwiftUI 里绑定 VM" / "VM 之间依赖注入" / "怎么注册一个共享服务"
- 需要在 iOS 项目里实现「组件化 DI + 共享服务 + 自动生命周期」这套架构
- 编写或 review 使用本框架的单元测试

## 心智模型（一页速查）

```
                [Service 注册式 DI]

ViewModelSpec      ——  服务注册声明（怎么建 / 按什么 key 共享 / 要不要永驻）
      │                模块级 `let`，就像 service locator 的 key
      ▼
ViewModelBinding   ——  DI 容器 / 宿主（SwiftUI / UIKit / 自定义 NSObject）
      │                引用计数自动管理实例销毁
      ▼
ViewModel（子类二选一；本身就是 ObservableObject）
    ├── ViewModel                —— 基础：listen/notifyListeners/update；也适合做纯 Service
    └── StateViewModel<State>    —— 带不可变 state，附 setState / listenState 等
```

> 💡 "ViewModel" 这个名字是历史包袱——它**不局限于 MVVM 里的那个 VM**。AuthService、ThemeStore、一个缓存器，只要你想跨模块共享 / 注入，都可以继承 `ViewModel` 然后当服务注册。

**三个不变式**

1. `binding.watch(spec)` / `read(spec)` → 引用计数 +1；`binding.dispose()` → 计数 −1；归零即销毁。
2. 同一个 `key` 的 spec 在**任何** binding 里都返回同一实例；没 `key` 的 spec 每次新建。
3. `aliveForever: true` → 引用计数归零也不销毁，常驻进程。

## Core API 对照

| 场景 | 用哪个基类 | 关键方法 |
| --- | --- | --- |
| 只需要事件通知（"更新了"） | `ViewModel` | `listen` / `notifyListeners` / `update { … }` |
| 管理一坨不可变状态 | `StateViewModel<State>` | `setState(_:)` / `listenState` / `listenStateSelect` |
| SwiftUI 里用 `@StateObject` | `ViewModel`（或 `StateViewModel<State>`） | 本身就是 `ObservableObject`，`notifyListeners()` 自动 `objectWillChange.send()` |

## 标准写法片段（逐条可复用）

### 1. 最基础的 StateViewModel

```swift
import AppleViewModel

struct CounterState: Equatable {
    var count: Int = 0
}

@MainActor
final class CounterViewModel: StateViewModel<CounterState> {
    init() { super.init(state: CounterState()) }

    func increment() {
        setState(CounterState(count: state.count + 1))
    }
}

let counterSpec = ViewModelSpec<CounterViewModel> { CounterViewModel() }
```

**关键点**：

- `setState` 传**整个新 state**，不是增量。框架内部做相等判断决定要不要 `notifyListeners`。
- state 最好 `Equatable`；或者在 `ViewModelConfig.equals` 里装一个全局比较函数；或者 `super.init(state:equals:)` 传实例级 equals。

### 2. SwiftUI 绑定

最常用：

```swift
struct CounterView: View {
    @WatchViewModel(counterSpec) var vm: CounterViewModel

    var body: some View {
        Button("\(vm.state.count)") { vm.increment() }
    }
}
```

变体：

- `@ReadViewModel(spec)` — 只创建/绑定，不订阅（不会触发重绘）。适合 VM 作为"服务"用。
- `ViewModelBuilder(spec) { vm in … }` — 不想写 property wrapper 时用 View 包装。
- `ObserverBuilder(observableValue) { … }` — 监听单个 `ObservableValue<T>`。
- `StateViewModelValueWatcher(viewModel: vm, selectors: [\.name]) { state in … }` — 细粒度重建，只关心某几个字段。

### 3. UIKit 绑定（UIViewController / UIView / 自定义 NSObject）

```swift
final class CounterVC: UIViewController, ViewModelBindingRefreshable {
    private lazy var vm = viewModelBinding.watch(counterSpec)
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(label)
        refresh()
    }

    func viewModelBindingDidUpdate() { refresh() }

    private func refresh() {
        label.text = "\(vm.state.count)"
    }
}
```

- `viewModelBinding` 是挂在 `NSObject` 上的关联对象，宿主 `deinit` 时自动 dispose。
- `UIView`、自定义 `NSObject` 宿主同样可用 — 继承自 NSObject 就行。
- 只想建 VM、不需要刷新回调时：不实现 `ViewModelBindingRefreshable` 即可。

### 4. 带参数的 spec（同参共享实例）

```swift
let userSpec = ViewModelSpecWithArg1<UserViewModel, String>(
    builder: { userId in UserViewModel(userId: userId) },
    key:     { userId in "user-\(userId)" }
)

// 使用
let vm1 = binding.watch(userSpec("abc"))  // 新建
let vm2 = binding.watch(userSpec("abc"))  // 同一实例
let vm3 = binding.watch(userSpec("xyz"))  // 另一实例
```

支持 1–4 参数：`ViewModelSpecWithArg1` / `2` / `3` / `4`。

### 5. 全局单例（aliveForever）

```swift
let authSpec = ViewModelSpec<AuthViewModel>(
    key: "auth",
    aliveForever: true
) { AuthViewModel() }
```

任何 binding `watch/read` 这个 spec 都拿到同一个 `AuthViewModel`，且它永不销毁。

### 6. VM 之间互相依赖注入（DI 核心能力）

这是 AppleViewModel 最关键的一项：**一个 VM 内部直接注入另一个 VM / 服务**。子 VM 自带 `viewModelBinding`，内部通过 `@TaskLocal` 解析到"创建它的那个 binding"，所以只要目标 spec 已注册，就能拿到实例。

```swift
// 模块 A：注册服务
let authSpec = ViewModelSpec<AuthViewModel>(key: "auth", aliveForever: true) { AuthViewModel() }
let cartSpec = ViewModelSpec<CartViewModel>(key: "cart") { CartViewModel() }

// 模块 B：业务 VM 里注入别人 export 的服务
@MainActor
final class OrderViewModel: ViewModel {
    // lazy：构造完才访问，避免 init 期间循环
    // read：只用不订阅；watch：会跟随对方 notify
    lazy var auth: AuthViewModel = viewModelBinding.read(authSpec)
    lazy var cart: CartViewModel = viewModelBinding.watch(cartSpec)
}
```

模块化收益：模块 A / B / C 各自 export 自己的 spec，使用方在外层 binding 拼装；测试时用 `setProxy` 换成 mock，不用改下游代码。父 binding dispose 时，如果 cart 没被别人持有，它也一起 dispose——引用计数自动收尾。

### 7. 配置入口（App 启动时装一次）

```swift
@main
struct MyApp: App {
    init() {
        ViewModel.initialize(
            config: ViewModelConfig(
                isLoggingEnabled: true,  // debug 时打开
                equals: { ($0 as? AnyHashable) == ($1 as? AnyHashable) },
                onError: { error, type in
                    Crashlytics.record(error: error, category: "\(type)")
                }
            ),
            lifecycles: [DebugLifecycleLogger()]
        )
    }
    var body: some Scene { /* … */ }
}
```

### 8. Pause / Resume（后台时暂停刷新）

```swift
let binding = ViewModelBinding()
binding.addPauseProvider(AppPauseProvider())  // 跟 UIScene 活跃状态联动
```

进入后台时 `notifyListeners` 会累积但不触发 UI 重建，回前台合并触发一次。

### 9. 单元测试的 setUp 模板

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
    func test_increment() {
        let binding = ViewModelBinding()
        defer { binding.dispose() }

        let vm = binding.watch(counterSpec)
        vm.increment()
        XCTAssertEqual(vm.state.count, 1)
    }
}
```

### 10. 用 setProxy 做 mock

```swift
func test_with_mock() {
    counterSpec.setProxy(ViewModelSpec { MockCounterViewModel() })
    defer { counterSpec.clearProxy() }

    let binding = ViewModelBinding()
    defer { binding.dispose() }

    let vm = binding.watch(counterSpec)
    XCTAssertTrue(vm is MockCounterViewModel)
}
```

## watch vs read 速查

| 方法 | 创建（没有则新建） | 绑定（计数 +1） | 订阅（触发刷新） |
| --- | :-: | :-: | :-: |
| `watch(spec)` | ✓ | ✓ | ✓ |
| `read(spec)` | ✓ | ✓ | ✗ |
| `watchCached(key:)` | ✗ 抛错 | ✓ | ✓ |
| `readCached(key:)` | ✗ 抛错 | ✓ | ✗ |
| `maybeWatchCached(key:)` | ✗ 返 nil | ✓ | ✓ |
| `maybeReadCached(key:)` | ✗ 返 nil | ✓ | ✗ |

## 常见陷阱

1. **别在 VM 的 `init` 里访问 `viewModelBinding`**。`@TaskLocal` 解析只在 `factory.build()` 执行期间有效，init 体内可以，但用 `lazy var` 更安全。
2. **`@MainActor` 是默认契约**。所有 VM / binding 类型都在主线程；后台活跃（网络、计算）要用 `Task.detached` 或自定义 actor 并显式 hop 回来调 `setState`。
3. **日志是例外**：`viewModelLog` / `reportViewModelError` 是 `nonisolated`，可以在 `@Sendable onError`、`AsyncStream.onTermination` 等非主线程上下文调用。
4. **相等判断优先级**（`StateViewModel`）：实例级 `equals` > 全局 `config.equals` > 类对象引用相等 / 值类型恒不等。state 是 struct 但没配全局 equals？`setState(sameStruct)` 会当作"变了"并触发 notify。
5. **`setUp` 是 nonisolated**。测试 reset 要包 `MainActor.assumeIsolated { … }`。
6. **别手动 `vm.dispose()`**。dispose 由 binding 引用计数驱动；想强制销毁 VM 用 `binding.recycle(vm)`。
7. **Spec 是模块级 `let`**。不要每个 View body 里重建 — 那样 key 虽然能共享但没必要，而且 `setProxy` 测试钩子会失效。

## 基类选择决策树

```
需要管理一份不可变 state？
├── 是 → StateViewModel<State>
└── 否 → ViewModel
```

`ViewModel` 本身就是 `ObservableObject`——`notifyListeners()` 会自动发 `objectWillChange`，可以直接塞进 `@StateObject` / `@ObservedObject`。SwiftUI 新代码推荐用 `StateViewModel<S>` + `@WatchViewModel`。

## 平台支持

- iOS 16+（主要目标）
- macOS 13+ / tvOS 16+ / watchOS 9+ / visionOS 1+（Core 层，用于 CI / 跨平台扩展）
- Swift 6.0+，全包启用 Swift 6 language mode 和严格并发

## 安装

```swift
// Package.swift
.package(url: "https://github.com/lwj1994/apple_view_model.git", from: "0.1.0"),

// target 依赖
.product(name: "AppleViewModel", package: "apple_view_model"),
```

或 Xcode → File → Add Package Dependencies → 粘贴 `https://github.com/lwj1994/apple_view_model.git`。

## 相关资源

- 仓库：<https://github.com/lwj1994/apple_view_model>
- CHANGELOG：仓库根 `CHANGELOG.md`
- Dart 原版：<https://github.com/lwj1994/flutter_view_model>（对照 Swift 移植思路）
- 速查地图：仓库 `AGENTS.md`（面向 AI 工具的项目速览）
