import AppleViewModel

@MainActor let postFeedViewModelSpec = ViewModelSpecWithArg<PostFeedViewModel, String>(
    builder: { PostFeedViewModel(userID: $0) },
    key: { "instagram.post-feed.\($0)" }
)

struct PostFeedState: Equatable {
    var phase: LoadPhase = .idle
    var posts: [Post] = []
    var errorMessage: String?
}

/// Owns the personalized feed for one user.
@MainActor
final class PostFeedViewModel: StateViewModel<PostFeedState> {
    let userID: String

    init(userID: String) {
        self.userID = userID
        super.init(state: PostFeedState(), equals: { $0 == $1 })
    }

    var repository: PostRepository {
        viewModelBinding.read(postRepositorySpec)
    }

    func load(force: Bool = false) async throws {
        guard state.phase != .loading else { return }
        guard force || state.phase != .ready else { return }

        setState(PostFeedState(phase: .loading, posts: state.posts))
        do {
            let posts = try await repository.feed(for: userID)
            setState(PostFeedState(phase: .ready, posts: posts))
        } catch {
            setState(PostFeedState(
                phase: .failure,
                posts: state.posts,
                errorMessage: String(describing: error)
            ))
            throw error
        }
    }
}
