import AppleViewModel
import SwiftUI

struct PostFeedView: View {
    let userID: String

    @WatchViewModel private var feedSource: PostFeedViewModel

    private var feed: PostFeedViewModel { feedSource }
    @WatchViewModel private var currentUserSource: UserViewModel

    private var currentUser: UserViewModel { currentUserSource }

    init(userID: String) {
        self.userID = userID
        _feedSource = WatchViewModel(postFeedViewModelSpec(userID))
        _currentUserSource = WatchViewModel(userViewModelSpec(userID))
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
