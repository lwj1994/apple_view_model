import AppleViewModel
import SwiftUI

struct PostFeedView: View {
    let userID: String

    @WatchViewModel private var feed: PostFeedViewModel
    @WatchViewModel private var currentUser: UserViewModel

    init(userID: String) {
        self.userID = userID
        _feed = WatchViewModel(postFeedViewModelSpec(userID))
        _currentUser = WatchViewModel(userViewModelSpec(userID))
    }

    var body: some View {
        List(feed.state.posts) { post in
            NavigationLink {
                PostDetailView(postID: post.id, currentUserID: userID)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("@\(post.author.username)")
                        .font(.headline)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(height: 220)
                        .overlay(Image(systemName: "photo").font(.largeTitle))
                    Text("♥ \(post.likeCount)")
                    Text(post.caption)
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(currentUser.state.user.map { "@\($0.username)" } ?? "Instagram VM")
        .task {
            // These keyed instances are shared with the startup coordinator.
            try? await currentUser.load()
            try? await feed.load()
        }
        .refreshable {
            try? await feed.load(force: true)
        }
    }
}
