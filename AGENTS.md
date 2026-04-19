# AGENTS.md

给 Claude / AI 工具用的项目速览。

## 一句话说清

`AppleViewModel` 把 Flutter 的 `view_model` 包原汁原味搬到 Apple，继承 `@TaskLocal` 做 DI、引用计数做生命周期、SwiftUI `@StateObject` + Combine 桥到视图层。所有对外 API 都 `@MainActor`。

## 目录地图

```
Sources/AppleViewModel/
├── Core/          ViewModel / StateViewModel、Spec / SpecArg、Config（含 ViewModelGlobalConfig）、Error、InstanceArg、Log
├── Registry/      Store<T>、InstanceHandle、InstanceManager、InstanceFactory、AutoDisposeInstanceController
├── Binding/       ViewModelBinding、HostedViewModelBinding、ViewModelBindingHandler、
│                  PauseAwareController、PauseProvider (+ Providers/)
├── Lifecycle/     ViewModelLifecycle、AutoDisposeController
├── Observable/    ObservableValue (+ ObservableStateViewModel)
└── UI/
    ├── SwiftUI/   @WatchViewModel / @ReadViewModel / ViewModelBuilder / ObserverBuilder / StateViewModelValueWatcher
    └── UIKit/     NSObject+ViewModel（真正实现）+ UIViewController+ViewModel（占位方便 API 发现）
```

- `Tests/AppleViewModelTests/`：每个核心机制对应一个测试文件，共 ~40 个用例。
- `Examples/CounterApp/`：可直接粘贴到 Xcode 新建工程里跑的 demo，不编入 Package。

## 核心不变式

1. **引用计数归零 = 销毁**。每个 binding 有唯一 `id`；`watch` 和 `read` 都会 `bind(id)`，binding dispose 时 `unbind(id)`。
2. **共享通过 `key`**。没 `key` 的 spec 每次都新建；有 `key` 的 spec 跨 binding 同一实例。
3. **`aliveForever = true` 永驻**。引用计数归零不触发销毁，直到进程退出。
4. **VM-to-VM 依赖走 TaskLocal**。`ViewModelBinding._createViewModel` 用 `ViewModelBinding.$current.withValue(self)` 建立上下文，VM 构造函数里的 `viewModelBinding` 能解析到父 binding。
5. **`@MainActor` 全包覆盖**（除日志外）。对外 API、所有 VM/binding 类型都在主线程；日志 (`viewModelLog`) 和错误上报 (`reportViewModelError`) 是 `nonisolated`，内部读取受锁保护的 `ViewModelGlobalConfig`，任何 actor、后台 `Task`、`@Sendable` 回调里都能安全调用。后台任务仍然通过 `Task.detached` 明确手动切线程。

## 边界（明确不做的）

- DevTools / 远程调试可视化（对应 Dart 的 `view_model_devtools_extension`）。
- 代码生成（对应 `view_model_generator`）。未来可考虑 Swift Macro。
- `PageRoutePauseProvider` / `TickerModePauseProvider`——iOS 导航栈模型差异大，需要再单独设计。
- 弃用别名 (`Vef` / `vef` / `ViewModelProvider` / `singleton()` 等)。

## 开发指令

```bash
swift build      # 编译（会同时做 iOS/macOS 目标的类型检查）
swift test       # 跑所有单元测试
```

## 发布流程（GitHub + tag）

SwiftPM 靠 git tag 做版本分发，没有中心化仓库。每次发版：

1. 更新 `CHANGELOG.md`：把 `[Unreleased]` 下的条目归并到新版本号，写清 Added / Changed / Fixed / Removed。
2. 本地跑一遍 `swift build && swift test`，确保干净。
3. 提交代码（commit 信息遵循根 CLAUDE.md 里定义的约束性 commit 规范，scope 用模块名）。
4. 打 tag 并推送：

   ```bash
   git tag 0.1.1                   # 语义化版本：破坏性改 → major；新增 → minor；修复 → patch
   git push origin main            # 先推代码
   git push origin 0.1.1           # 再推 tag
   ```

5. （可选）在 GitHub Releases 页基于该 tag 写 Release Notes，直接复制 CHANGELOG 对应段落即可。

**重要**：tag 一旦推到 GitHub 就不要移动——下游 app 已经锁定 `from: "0.1.1"` 或 `.exact("0.1.1")` 时，tag 漂移会引发"看似同一版本但内容不同"的诡异问题。需要修正就发 0.1.2。

## 版本号选择

- `0.x.y`：初版阶段，任何 minor (`0.x → 0.(x+1)`) 都允许包含破坏性改动。
- `1.0.0` 之后：严格遵循 SemVer，破坏性改动必须撞 major。
- `Unreleased` 段落永远保留，用来收集下一版还没发的变更。

## 碰到什么改什么

- **加新的生命周期钩子**：同时改 `InstanceLifeCycle`（协议）、`ViewModel`（默认实现调 `ViewModelLifecycle`）、`InstanceHandle`（调用点）。
- **加新 PauseProvider**：继承 `BasePauseProvider`，在 `init` 订阅你关心的事件并在事件回调里调 `pause()` / `resume()`。
- **加新 SwiftUI 积木**：看 `WatchViewModel.swift` 的实现套路——包一个 `ObservableObject` host 持有 `HostedViewModelBinding`，refresh 闭包调 `objectWillChange.send()`。

## 常见坑

- Swift 6 的 deinit 默认 nonisolated，访问 @MainActor 成员要避开或用 `isolated deinit`（见 `StateViewModelValueWatcher.swift` 里的注释）。
- `InstanceFactory`/`InstanceManager.get` 是 internal；外部 API 都统一走 `ViewModelBinding`。
- 测试里 `setUp()` 是 nonisolated 的，用 `MainActor.assumeIsolated { … }` 包 reset 逻辑。
