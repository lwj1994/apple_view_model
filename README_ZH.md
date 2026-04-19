# AppleViewModel

简体中文 · See [README.md](./README.md) for full documentation.

**AppleViewModel 本质上是一个 DI 框架**，为 Apple 平台提供组件级依赖注入，默认无缝集成 SwiftUI 与 UIKit。从 Flutter 包 [`view_model`](https://github.com/lwj1994/flutter_view_model) 移植而来。

核心理念：**任何东西都可以写成 `ViewModel` 形式**——业务状态、Repository、网络服务、全局 Store……继承 `ViewModel` + 通过 `ViewModelSpec` 注册，就能在模块之间互相复用、引用、注入。

- **Service 注册式 DI**：`ViewModelSpec` 声明注册规则，`binding.watch` / `binding.read` 获取实例；VM 内部用 `viewModelBinding` 拿别的 VM，天然 VM-to-VM 依赖。
- **生命周期自动化**：引用计数驱动，宿主释放时自动 dispose。
- **默认双端 UI**：SwiftUI（`@WatchViewModel` 等）+ UIKit（`NSObject.viewModelBinding`）。`ViewModel` 本身就是 `ObservableObject`，直接塞进 `@StateObject` 即可。
- 所有对外 API 统一 `@MainActor`，Swift 6 严格并发。

## 快速上手

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

struct CounterView: View {
    @WatchViewModel(counterSpec) var vm: CounterViewModel
    var body: some View {
        Button("\(vm.state.count)") { vm.increment() }
    }
}
```

更完整的说明、对照表、测试用法请看 [README.md](./README.md)。

## License

Apache-2.0
