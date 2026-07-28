import AppleViewModel
import SwiftUI

@main
struct InstagramArchitectureApp: App {
    init() {
        ViewModel.initialize()
    }

    var body: some Scene {
        WindowGroup {
            InstagramRootView(currentUserID: "user-milu")
        }
    }
}

struct InstagramRootView: View {
    let currentUserID: String

    @WatchViewModel private var startup: InitViewModel

    init(currentUserID: String) {
        self.currentUserID = currentUserID
        _startup = WatchViewModel(initViewModelSpec(currentUserID))
    }

    var body: some View {
        NavigationStack {
            switch startup.state.phase {
            case .ready:
                PostFeedView(userID: currentUserID)
            case .failure:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Startup failed")
                        .font(.headline)
                    Text(startup.state.errorMessage ?? "Unknown error")
                }
            case .idle, .loading:
                ProgressView("Starting Instagram VM")
            }
        }
        .task {
            try? await startup.initialize()
        }
    }
}
