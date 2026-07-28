import AppleViewModel

@MainActor let postDetailViewModelSpec = ViewModelSpecWithArg2<
    PostDetailViewModel,
    String,
    String
>(
    builder: { PostDetailViewModel(postID: $0, currentUserID: $1) },
    key: { "instagram.post-detail.\($1).\($0)" }
)

struct PostDetailState: Equatable {
    var phase: LoadPhase = .idle
    var post: Post?
    var errorMessage: String?
}

/// Owns one post-detail dependency subtree.
@MainActor
final class PostDetailViewModel: StateViewModel<PostDetailState> {
    let postID: String
    let currentUserID: String

    init(postID: String, currentUserID: String) {
        self.postID = postID
        self.currentUserID = currentUserID
        super.init(state: PostDetailState(), equals: { $0 == $1 })
    }

    var repository: PostRepository {
        viewModelBinding.read(postRepositorySpec)
    }

    // Watch makes comment changes notify this module and then its root view.
    var comments: CommentViewModel {
        viewModelBinding.watch(commentViewModelSpec(postID, currentUserID))
    }

    func load() async {
        guard state.phase != .loading && state.phase != .ready else { return }
        setState(PostDetailState(phase: .loading))

        do {
            let commentsModule = comments
            async let postTask = repository.post(id: postID)
            async let commentsTask: Void = commentsModule.load()
            let post = try await postTask
            try await commentsTask
            setState(PostDetailState(phase: .ready, post: post))
        } catch {
            setState(PostDetailState(
                phase: .failure,
                errorMessage: String(describing: error)
            ))
        }
    }

    func addComment(_ message: String) async throws {
        try await comments.add(message)
    }
}
