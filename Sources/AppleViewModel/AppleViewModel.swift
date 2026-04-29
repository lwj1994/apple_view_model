// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 luwenjie (Echoingtech)
//
/// # AppleViewModel
///
/// Apple-native port of the Flutter package
/// [`view_model`](https://github.com/lwj1994/flutter_view_model).
///
/// ## Three pieces to learn
///
/// 1. **`ViewModel` / `StateViewModel<State>`**
///    — subclass one to define a VM. Every `ViewModel` is also an `ObservableObject`,
///    so instances drop straight into SwiftUI `@StateObject` / `@ObservedObject`.
/// 2. **`ViewModelSpec` / `ViewModelSpecWithArg…`**
///    — declare how the VM is built and whether instances are shared.
/// 3. **`ViewModelBinding` / `@WatchViewModel` / `NSObject.viewModelBinding`**
///    — host the VM from SwiftUI, UIKit, AppKit-compatible object graphs, or plain Swift.
///
/// ## Quick Start
///
/// ```swift
/// import AppleViewModel
///
/// final class CounterViewModel: ViewModel {
///     private(set) var count = 0
///     func increment() {
///         update { count += 1 }
///     }
/// }
///
/// let counterSpec = ViewModelSpec<CounterViewModel> {
///     CounterViewModel()
/// }
///
/// struct CounterView: View {
///     @WatchViewModel(counterSpec) var vm: CounterViewModel
///     var body: some View {
///         Button("\(vm.count)") { vm.increment() }
///     }
/// }
/// ```
///
/// See `README.md`.
@_exported import Foundation
