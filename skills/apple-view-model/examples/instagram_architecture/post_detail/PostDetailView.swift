import AppleViewModel
import SwiftUI

struct PostDetailView: View {
    let postID: String
    let currentUserID: String

    @WatchViewModel private var detail: PostDetailViewModel
    @State private var message = ""

    init(postID: String, currentUserID: String) {
        self.postID = postID
        self.currentUserID = currentUserID
        _detail = WatchViewModel(postDetailViewModelSpec(postID, currentUserID))
    }

    var body: some View {
        Group {
            switch detail.state.phase {
            case .ready:
                if let post = detail.state.post {
                    List {
                        Section("Post") {
                            Text("@\(post.author.username)")
                            Text(post.caption)
                        }

                        Section("Comments") {
                            ForEach(detail.comments.state.comments) { comment in
                                VStack(alignment: .leading) {
                                    Text("@\(comment.author.username)")
                                        .font(.headline)
                                    Text(comment.message)
                                }
                            }

                            TextField("Add a comment", text: $message)
                            Button(detail.comments.state.isSubmitting ? "Sending" : "Send") {
                                let submittedMessage = message
                                message = ""
                                Task {
                                    try? await detail.addComment(submittedMessage)
                                }
                            }
                            .disabled(detail.comments.state.isSubmitting)
                        }
                    }
                }
            case .failure:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Post failed to load")
                        .font(.headline)
                    Text(detail.state.errorMessage ?? "Unknown error")
                }
            case .idle, .loading:
                ProgressView("Loading post")
            }
        }
        .navigationTitle("Post detail")
        .task {
            await detail.load()
        }
    }
}
