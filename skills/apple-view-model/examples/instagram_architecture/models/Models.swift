import Foundation

struct User: Identifiable, Hashable, Sendable {
    let id: String
    let username: String
    let displayName: String
}

struct Post: Identifiable, Hashable, Sendable {
    let id: String
    let author: User
    let caption: String
    let likeCount: Int
}

struct Comment: Identifiable, Hashable, Sendable {
    let id: String
    let postID: String
    let author: User
    let message: String
}
