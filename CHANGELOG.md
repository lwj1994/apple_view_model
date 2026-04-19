# Changelog

所有重要变更都记录在这里。

版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)：

- `Added` 新功能
- `Changed` 已有功能的改动
- `Deprecated` 即将移除的 API
- `Removed` 已移除的 API
- `Fixed` Bug 修复
- `Security` 安全相关修复

---

## [Unreleased]

## [0.2.0] - 2026-04-19

### Changed

- `ViewModel` 本身现在直接实现 `ObservableObject`，`notifyListeners()` 会自动触发 `objectWillChange.send()`——所有 VM 都可以直接塞进 SwiftUI `@StateObject` / `@ObservedObject`。
- 文档重新定位：README / SKILL / AGENTS 把本包描述为 **Apple 平台的 DI 框架（Service 注册式）**，默认集成 SwiftUI + UIKit，强调 "任何东西都可以写成 ViewModel" 和模块间互相注入能力。

### Removed

- **破坏性**：移除 `ObservableViewModel` 基类（以及弃用别名 `ChangeNotifierViewModel`）。原先提供的能力已下沉到 `ViewModel`。迁移路径：把所有 `: ObservableViewModel` 改成 `: ViewModel` 即可，API 行为一致。

## [0.1.0] - 2026-04-18

首次发布。从 Flutter 包 [`view_model`](https://github.com/lwj1994/flutter_view_model) 移植到 Apple 平台。

### Added

- **Core 两件套**
  - `ViewModel`：基础基类，提供 `listen` / `notifyListeners` / `update` / `addDispose` 和生命周期钩子（`onCreate` / `onBind` / `onUnbind` / `onDispose`）。
  - `StateViewModel<State>`：不可变 state 管理，`setState` / `listenState` / `listenStateSelect`，相等判断支持实例级 / 全局 / 默认三级策略。
- **Spec / Factory**
  - `ViewModelSpec<T>`：零参工厂声明。
  - `ViewModelSpecWithArg1..4`：1–4 个参数的工厂，`callAsFunction` 应用参数生成子 spec。
  - 通用 `key` / `tag` / `aliveForever` 机制控制共享与生命周期。
  - `setProxy` / `clearProxy`：测试时的 builder 替换。
- **Registry**
  - `InstanceManager` / `Store<T>` / `InstanceHandle` / `InstanceFactory`：按 `ObjectIdentifier(T.self)` 分桶、按 `key` 共享的实例注册表，附带 `bindingIds` 引用计数。
- **Binding**
  - `ViewModelBinding` + `HostedViewModelBinding`：任意宿主持有 VM 的容器，支持 `watch` / `read` / `watchCached` / `readCached` / `maybeWatchCached` / `maybeReadCached`。
  - `ViewModelBindingHandler`：VM 内部依赖解析器（SPI 隐藏）。
  - `@TaskLocal static var current: ViewModelBinding?`：Swift 版 Zone，供 VM 之间注入依赖。
- **Pause / Resume**
  - `PauseAwareController` + `BasePauseProvider`（`AsyncStream<Bool>` 驱动）。
  - `AppPauseProvider` 订阅 `UIScene.willDeactivateNotification` / `didActivateNotification`。
  - `UIKitVisibilityPauseProvider`（UIKit view/controller 可见性）。
- **SwiftUI 集成**
  - `@WatchViewModel(spec)` / `@ReadViewModel(spec)` property wrappers。
  - `ViewModelBuilder(spec) { vm in … }` / `CachedViewModelBuilder`。
  - `ObserverBuilder(value) { … }`：`ObservableValue` 的便捷绑定。
  - `StateViewModelValueWatcher`：基于 `listenStateSelect` 的细粒度重建。
- **UIKit / NSObject 集成**
  - `NSObject.viewModelBinding`：关联对象挂载的 `HostedViewModelBinding`，宿主释放时自动 dispose。
  - `ViewModelBindingRefreshable` 协议：需要时实现 `viewModelBindingDidUpdate()` 接收刷新通知。
  - `UIViewController` 继承 NSObject，自动复用。
- **Observable**
  - `ObservableValue<T>` + `ObservableStateViewModel<T>`：轻量可订阅值，底层走 `StateViewModel` + `shareKey`。
- **Configuration**
  - `ViewModelConfig`：`isLoggingEnabled` / 全局 `equals` / 全局 `onError`。
  - `ViewModelLifecycle`：进程级生命周期观察者。
  - `ViewModel.initialize(config:lifecycles:)` / `ViewModel.addLifecycle(_:)`。
- **Logging**
  - 基于 `os.Logger`，`subsystem: "tech.echoing.AppleViewModel"`。
  - `viewModelLog` / `reportViewModelError` 是 `nonisolated`，可在任何 actor、后台 Task、`@Sendable` 回调中安全调用。全局 config 通过 `OSAllocatedUnfairLock` 保护。

### Platforms

- iOS 16+（主要目标）
- macOS 13+ / tvOS 16+ / watchOS 9+ / visionOS 1+（Core 层编译通过，供 CI 与未来扩展）
- Swift 6.0+，全包启用 Swift 6 language mode 和严格并发

### Tests

- 40 个单元测试覆盖基础 VM、StateVM、Binding watch/read、Spec 共享、参数 spec、依赖注入、生命周期、pause/resume、ObservableValue 等全部核心机制。
