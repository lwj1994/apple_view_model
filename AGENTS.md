# AGENTS.md

给 Claude / AI 工具用的项目速览。

## 一句话说清

`AppleViewModel` 把 Flutter 的 `view_model` 包原汁原味搬到 Apple：parent generation 自带稳定 dependency binding 做 VM-to-VM DI，source-aware 引用计数做生命周期，SwiftUI `@StateObject` + Combine 桥到视图层。所有对外 API 都 `@MainActor`。

## 目录地图

```
Sources/AppleViewModel/
├── Core/          ViewModel / StateViewModel、Spec / SpecArg、Config（含 ViewModelGlobalConfig）、Error、InstanceArg、Log
├── Registry/      Store<T>、InstanceHandle、InstanceManager、InstanceFactory、AutoDisposeInstanceController
├── Binding/       ViewModelBinding、HostedViewModelBinding、ViewModelBindingHandler、
│                  ViewModelDependencyBinding、PauseAwareController、PauseProvider (+ Providers/)
├── Lifecycle/     ViewModelLifecycle、AutoDisposeController
└── UI/
    ├── SwiftUI/   @WatchViewModel / @ReadViewModel / StateViewModelSelector / StateViewModelValueWatcher
    └── UIKit/     NSObject+ViewModel（真正实现）+ UIViewController+ViewModel（占位方便 API 发现）
```

- `Tests/AppleViewModelTests/`：每个核心机制对应一个测试文件。
- `Examples/CounterApp/`：可直接粘贴到 Xcode 新建工程里跑的 demo，不编入 Package。

## 核心不变式

1. **引用计数归零 = 销毁**。每个 binding 有唯一 `id`；`watch` 和 `read` 都会 `bind(id)`，binding dispose 时 `unbind(id)`。
2. **默认 identity 是类型 + binding 私有 key**。同一 binding 内同一 VM 类型复用；不同 binding 默认隔离。显式 `key` 用于跨 binding 共享，或同一 binding 内区分多个同类型实例。
3. **`aliveForever = true` 必须配显式 key**。root 与 nested 解析统一在 builder 执行前校验，底层 Store 也必须兜底；引用计数归零时实例仍留在缓存，但显式 `recycle` 与 `ViewModel.reset()` 仍会强制销毁。
4. **VM-to-VM 依赖属于 parent generation**。每个 parent 对象延迟持有一个稳定 dependency binding；它保活已解析 child、实时传播 root owners，并用 source-aware 路径避免 direct/parent 引用互相误删。构造 stack 只负责 init/onCreate 阶段的首批 root owner 发现。
5. **嵌套依赖用计算属性解析**。不要用 `lazy var`/stored property 缓存 child；显式 recycle 后必须能通过 getter 重新解析新 generation。
6. **`@MainActor` 全包覆盖**（除日志外）。对外 API、所有 VM/binding 类型都在主线程；日志 (`viewModelLog`) 和错误上报 (`reportViewModelError`) 是 `nonisolated`，内部读取受锁保护的 `ViewModelGlobalConfig`，任何 actor、后台 `Task`、`@Sendable` 回调里都能安全调用。后台任务仍然通过 `Task.detached` 明确手动切线程。
7. **稳定 spec 的 `watch/read` 是主入口**。两者都会创建/获取、bind 并观察 handle disposal；只有 `watch` 监听 VM 自身通知。即使 spec 带 key/tag，也继续传 spec；cached API 只查询其他路径已创建的实例，是高级 escape hatch，不能与主入口并列推荐或替代 spec-based 解析。README、Skill、示例与公开 API 注释都必须保持这个优先级。
8. **不提供原位替换实例的 `recreate` API**。需要独立新实例时使用显式新 key；若明确接受影响所有 owners，则先全局 `recycle`，再由 resolver getter 通过 `watch/read(spec)` 走正常 cache-miss 路径创建新 handle 与 dependency tree，不迁移旧对象关系。

## 边界（明确不做的）

- DevTools / 远程调试可视化（对应 Dart 的 `view_model_devtools_extension`）。
- 代码生成（对应 `view_model_generator`）。未来可考虑 Swift Macro。
- `PageRoutePauseProvider` / `TickerModePauseProvider`——iOS 导航栈模型差异大，需要再单独设计。
- 弃用别名 (`Vef` / `vef` / `ViewModelProvider` / `singleton()` 等)。

## 开发指令

```bash
swift build      # 编译（会同时做 iOS/macOS 目标的类型检查）
swift test --no-parallel  # 单线程、按 XCTest 顺序跑测试
```

测试必须串行执行，禁止 `--parallel`、测试分片或并发 suite。全局 registry、
配置、生命周期观察器和 spec proxy 会在用例间 reset，并行执行会造成跨用例污染。

## 测试规则

- ViewModel 构造调用必须放在 `ViewModelSpec` builder 内；测试体和 `setUp()`
  不得直接实例化受管 ViewModel。
- 不要把 ViewModel 保存在测试类的 stored property；需要共享 fixture 时，用
  计算属性从测试 binding 重新解析。
- 每个测试 binding 都必须 `dispose()`，全局 reset 放在
  `MainActor.assumeIsolated` 中。
- 始终使用 `swift test --no-parallel`，不得开启并发或分片。

## 发布流程（GitHub + tag）

SwiftPM 靠 git tag 做版本分发，没有中心化仓库。每次发版：

1. 更新 `CHANGELOG.md`：把 `[Unreleased]` 下的条目归并到新版本号，写清 Added / Changed / Fixed / Removed。
2. 本地跑一遍 `swift build && swift test --no-parallel`，确保干净。
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
