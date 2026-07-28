import AppleViewModel

@MainActor let initViewModelSpec = ViewModelSpecWithArg<InitViewModel, String>(
    builder: { InitViewModel(currentUserID: $0) },
    key: { "instagram.init.\($0)" }
)

struct InitState: Equatable {
    var phase: LoadPhase = .idle
    var errorMessage: String?
}

/// Coordinates startup order without owning user or feed behavior.
@MainActor
final class InitViewModel: StateViewModel<InitState> {
    let currentUserID: String

    init(currentUserID: String) {
        self.currentUserID = currentUserID
        super.init(state: InitState(), equals: { $0 == $1 })
    }

    var user: UserViewModel {
        viewModelBinding.read(userViewModelSpec(currentUserID))
    }

    var feed: PostFeedViewModel {
        viewModelBinding.read(postFeedViewModelSpec(currentUserID))
    }

    func initialize() async throws {
        guard state.phase != .loading && state.phase != .ready else { return }
        setState(InitState(phase: .loading))

        do {
            // Feed loading requires the restored current-user module first.
            try await user.load()
            try await feed.load()
            setState(InitState(phase: .ready))
        } catch {
            setState(InitState(
                phase: .failure,
                errorMessage: String(describing: error)
            ))
            throw error
        }
    }
}
