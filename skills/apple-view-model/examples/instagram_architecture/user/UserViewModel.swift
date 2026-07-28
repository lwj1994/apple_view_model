import AppleViewModel

@MainActor let userViewModelSpec = ViewModelSpecWithArg<UserViewModel, String>(
    builder: { UserViewModel(userID: $0) },
    key: { "instagram.user.\($0)" }
)

struct UserState: Equatable {
    var phase: LoadPhase = .idle
    var user: User?
    var errorMessage: String?
}

/// Loads and exposes one user identified by `userID`.
@MainActor
final class UserViewModel: StateViewModel<UserState> {
    let userID: String

    init(userID: String) {
        self.userID = userID
        super.init(state: UserState(), equals: { $0 == $1 })
    }

    // Repository notifications do not need to refresh this feature module.
    var repository: UserRepository {
        viewModelBinding.read(userRepositorySpec)
    }

    func load(force: Bool = false) async throws {
        guard state.phase != .loading else { return }
        guard force || state.phase != .ready else { return }

        setState(UserState(phase: .loading, user: state.user))
        do {
            let user = try await repository.user(id: userID)
            setState(UserState(phase: .ready, user: user))
        } catch {
            setState(UserState(
                phase: .failure,
                user: state.user,
                errorMessage: String(describing: error)
            ))
            throw error
        }
    }
}
