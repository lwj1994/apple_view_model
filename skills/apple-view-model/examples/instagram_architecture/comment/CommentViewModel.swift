import AppleViewModel

@MainActor let commentViewModelSpec = ViewModelSpecWithArg2<
    CommentViewModel,
    String,
    String
>(
    builder: { CommentViewModel(postID: $0, currentUserID: $1) },
    key: { "instagram.comments.\($1).\($0)" }
)

struct CommentState: Equatable {
    var phase: LoadPhase = .idle
    var comments: [Comment] = []
    var isSubmitting = false
    var errorMessage: String?
}

/// Owns comments for one post and writes as the current user.
@MainActor
final class CommentViewModel: StateViewModel<CommentState> {
    let postID: String
    let currentUserID: String

    init(postID: String, currentUserID: String) {
        self.postID = postID
        self.currentUserID = currentUserID
        super.init(state: CommentState(), equals: { $0 == $1 })
    }

    var repository: CommentRepository {
        viewModelBinding.read(commentRepositorySpec)
    }

    // This resolves the same keyed UserViewModel used by startup.
    var currentUser: UserViewModel {
        viewModelBinding.read(userViewModelSpec(currentUserID))
    }

    func load() async throws {
        guard state.phase != .loading && state.phase != .ready else { return }

        setState(CommentState(phase: .loading, comments: state.comments))
        do {
            let comments = try await repository.comments(for: postID)
            setState(CommentState(phase: .ready, comments: comments))
        } catch {
            setState(CommentState(
                phase: .failure,
                comments: state.comments,
                errorMessage: String(describing: error)
            ))
            throw error
        }
    }

    func add(_ rawMessage: String) async throws {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty && !state.isSubmitting else { return }
        guard let author = currentUser.state.user else {
            throw InstagramDemoError.startupOrder
        }

        setState(CommentState(
            phase: state.phase,
            comments: state.comments,
            isSubmitting: true
        ))
        do {
            let comment = try await repository.addComment(
                postID: postID,
                author: author,
                message: message
            )
            setState(CommentState(
                phase: .ready,
                comments: state.comments + [comment]
            ))
        } catch {
            setState(CommentState(
                phase: state.phase,
                comments: state.comments,
                errorMessage: String(describing: error)
            ))
            throw error
        }
    }
}
