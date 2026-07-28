import AppleViewModel

@MainActor let commentRepositorySpec = ViewModelSpec<CommentRepository>(
    key: "instagram.comment-repository"
) {
    CommentRepository()
}

@MainActor
final class CommentRepository: ViewModel {
    var api: InstagramAPI { viewModelBinding.read(instagramAPISpec) }

    func comments(for postID: String) async throws -> [Comment] {
        try await api.fetchComments(for: postID)
    }

    func addComment(
        postID: String,
        author: User,
        message: String
    ) async throws -> Comment {
        try await api.createComment(
            postID: postID,
            author: author,
            message: message
        )
    }
}
