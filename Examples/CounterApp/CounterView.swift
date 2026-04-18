import SwiftUI
import AppleViewModel

/// Typical SwiftUI usage. `@WatchViewModel` routes every `setState` /
/// `notifyListeners` call through `objectWillChange`, so the view rebuilds as
/// expected.
struct CounterView: View {
    @WatchViewModel(counterSpec) private var vm: CounterViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Count: \(vm.state.count)")
                .font(.largeTitle)

            TextField("Label", text: Binding(
                get: { vm.state.label },
                set: { vm.updateLabel($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)

            if !vm.state.label.isEmpty {
                Text(vm.state.label).foregroundStyle(.secondary)
            }

            Button("+1") {
                vm.increment()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

/// `ObservableValue` is the escape hatch for cross-component state that does not
/// need a fully-featured ViewModel: any two call sites sharing the `shareKey`
/// read/write the same slot.
let darkModeValue = ObservableValue<Bool>(initialValue: false, shareKey: "theme-dark")

struct ThemeToggle: View {
    var body: some View {
        ObserverBuilder(observable: darkModeValue) { dark in
            Toggle("Dark mode", isOn: Binding(
                get: { dark },
                set: { darkModeValue.value = $0 }
            ))
            .padding()
        }
    }
}
