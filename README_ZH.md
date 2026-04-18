# AppleViewModel

简体中文 · See [README.md](./README.md) for full documentation.

从 Flutter 包 [`view_model`](https://github.com/lwj1994/flutter_view_model) 移植而来的 Apple 平台组件级 ViewModel 框架。

- 基于 `@TaskLocal` 做 VM 之间的依赖注入；
- 基于引用计数管理实例生命周期；
- 通过 SwiftUI `@StateObject` + Combine `ObservableObject.objectWillChange` 驱动视图更新；
- 所有对外 API 统一 `@MainActor`。

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
