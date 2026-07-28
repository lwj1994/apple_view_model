import AppleViewModel
import Foundation

@MainActor let instagramAPISpec = ViewModelSpec<InstagramAPI>(key: "instagram.api") {
    InstagramAPI()
}

/// Simulates a remote API with in-memory data so the architecture stays visible.
@MainActor
final class InstagramAPI: ViewModel {
    private static let currentUser = User(
        id: "user-milu",
        username: "milu",
        displayName: "Milu"
    )

    private static let ada = User(
        id: "user-ada",
        username: "ada",
        displayName: "Ada Lovelace"
    )

    private static let linus = User(
        id: "user-linus",
        username: "linus",
        displayName: "Linus Torvalds"
    )

    private let users = [
        InstagramAPI.currentUser,
        InstagramAPI.ada,
        InstagramAPI.linus,
    ]

    private let posts = [
        Post(
            id: "post-1",
            author: InstagramAPI.ada,
            caption: "Break complex systems into modules with clear boundaries.",
            likeCount: 1_842
        ),
        Post(
            id: "post-2",
            author: InstagramAPI.linus,
            caption: "Good architecture makes lifecycle relationships visible.",
            likeCount: 936
        ),
    ]

    private var comments: [String: [Comment]] = [
        "post-1": [
            Comment(
                id: "comment-1",
                postID: "post-1",
                author: InstagramAPI.currentUser,
                message: "The dependency graph is easy to follow."
            ),
        ],
        "post-2": [],
    ]

    private var nextCommentID = 2

    func fetchUser(_ userID: String) async throws -> User {
        try await simulateLatency()
        guard let user = users.first(where: { $0.id == userID }) else {
            throw InstagramDemoError.missingEntity(userID)
        }
        return user
    }

    func fetchFeed(for userID: String) async throws -> [Post] {
        _ = try await fetchUser(userID)
        return posts
    }

    func fetchPost(_ postID: String) async throws -> Post {
        try await simulateLatency()
        guard let post = posts.first(where: { $0.id == postID }) else {
            throw InstagramDemoError.missingEntity(postID)
        }
        return post
    }

    func fetchComments(for postID: String) async throws -> [Comment] {
        try await simulateLatency()
        return comments[postID, default: []]
    }

    func createComment(
        postID: String,
        author: User,
        message: String
    ) async throws -> Comment {
        try await simulateLatency()
        let comment = Comment(
            id: "comment-\(nextCommentID)",
            postID: postID,
            author: author,
            message: message
        )
        nextCommentID += 1
        comments[postID, default: []].append(comment)
        return comment
    }

    private func simulateLatency() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }
}
