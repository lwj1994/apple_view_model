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
