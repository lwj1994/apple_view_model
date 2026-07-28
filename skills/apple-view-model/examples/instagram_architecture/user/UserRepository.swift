import AppleViewModel

@MainActor let userRepositorySpec = ViewModelSpec<UserRepository>(
    key: "instagram.user-repository"
) {
    UserRepository()
}

@MainActor
final class UserRepository: ViewModel {
    var api: InstagramAPI { viewModelBinding.read(instagramAPISpec) }

    func user(id: String) async throws -> User {
        try await api.fetchUser(id)
    }
}
