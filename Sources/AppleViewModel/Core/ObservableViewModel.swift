import Foundation
import Combine

/// Convenience base class that is both a `ViewModel` and a SwiftUI
/// `ObservableObject`.
///
/// Covers the Dart `ChangeNotifierViewModel` use case while mapping cleanly onto
/// Combine: every `notifyListeners()` call first triggers `objectWillChange.send()`
/// so SwiftUI views observing the instance are re-rendered on the next tick,
/// then dispatches to the framework's own listener list.
///
/// If you are using `@WatchViewModel` you rarely need this class directly — it is
/// intended for code that wants to hand the VM to `@ObservedObject` / `@StateObject`
/// without a binding in between.
@MainActor
open class ObservableViewModel: ViewModel, ObservableObject {
    public override init() {
        super.init()
    }

    public override func notifyListeners() {
        // `objectWillChange` is conventionally sent before the mutation completes,
        // but Dart-style ViewModels mutate first and then call `notifyListeners`.
        // Emitting here is still correct — SwiftUI re-reads the properties on the
        // next run loop iteration, by which time the mutation is visible.
        objectWillChange.send()
        super.notifyListeners()
    }
}

/// Legacy name retained to ease migration of any early adopter code that
/// referenced the Dart-style identifier. New code should prefer
/// `ObservableViewModel`.
@available(*, deprecated, renamed: "ObservableViewModel")
public typealias ChangeNotifierViewModel = ObservableViewModel
