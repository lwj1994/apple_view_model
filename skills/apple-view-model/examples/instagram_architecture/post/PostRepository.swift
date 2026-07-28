import AppleViewModel

@MainActor let postRepositorySpec = ViewModelSpec<PostRepository>(
    key: "instagram.post-repository"
) {
    PostRepository()
}

@MainActor
final class PostRepository: ViewModel {
    var api: InstagramAPI { viewModelBinding.read(instagramAPISpec) }

    func feed(for userID: String) async throws -> [Post] {
        try await api.fetchFeed(for: userID)
    }

    func post(id: String) async throws -> Post {
        try await api.fetchPost(id)
    }
}
