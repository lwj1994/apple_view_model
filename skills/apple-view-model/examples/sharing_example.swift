import SwiftUI
import AppleViewModel

@MainActor
final class DraftViewModel: ViewModel {
    let documentID: String
    private(set) var title = ""

    init(documentID: String) {
        self.documentID = documentID
        super.init()
    }

    func updateTitle(_ value: String) {
        update { title = value }
    }
}

/// The explicit key lets bindings on different pages resolve the same instance.
///
/// `aliveForever` remains at its default value of `false`, so the instance is
/// automatically reclaimed after the final page unbinds. The document ID also
/// identifies the shared scope and prevents concurrent edits of different
/// documents from accidentally sharing state.
let draftViewModelSpec = ViewModelSpecWithArg<DraftViewModel, String>(
    builder: { DraftViewModel(documentID: $0) },
    key: { "draft-\($0)" }
)

struct SharingExampleView: View {
    var body: some View {
        NavigationStack {
            PageA(documentID: "document-42")
        }
    }
}

struct PageA: View {
    let documentID: String
    @WatchViewModel private var draftSource: DraftViewModel

    private var draft: DraftViewModel { draftSource }

    init(documentID: String) {
        self.documentID = documentID
        _draftSource = WatchViewModel(draftViewModelSpec(documentID))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(draft.title.isEmpty ? "Untitled" : draft.title)

            NavigationLink("Edit") {
                PageB(documentID: documentID)
            }
        }
        .navigationTitle("Preview")
    }
}

struct PageB: View {
    @WatchViewModel private var draftSource: DraftViewModel

    private var draft: DraftViewModel { draftSource }

    init(documentID: String) {
        _draftSource = WatchViewModel(draftViewModelSpec(documentID))
    }

    var body: some View {
        TextField(
            "Title",
            text: Binding(
                get: { draft.title },
                set: { draft.updateTitle($0) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .padding()
        .navigationTitle("Edit")
    }
}
