# Instagram Multi-Module Architecture Example

This is an illustrative SwiftUI application organized by functional module.
It mirrors the Flutter `view_model` skill's Instagram example while using
AppleViewModel APIs and Apple lifecycle conventions.

The directory is documentation source for the bundled skill. It is
intentionally excluded from the Swift Package target and is not required to
compile as a standalone application. Copy the files into an iOS 16+ Xcode app
target and adjust module imports if you want to run it.

## Directory Structure

```text
instagram_architecture/
├── README.md
├── app/
│   ├── InstagramApp.swift          # App entry point and root binding
│   └── InitViewModel.swift         # Startup flow coordinator
├── core/
│   ├── InstagramAPI.swift          # Shared remote-capability ViewModel
│   └── LoadPhase.swift
├── models/
│   └── Models.swift
├── user/
│   ├── UserRepository.swift
│   └── UserViewModel.swift
├── post/
│   └── PostRepository.swift        # Shared by feed and post detail
├── feed/
│   ├── PostFeedView.swift
│   └── PostFeedViewModel.swift
├── comment/
│   ├── CommentRepository.swift
│   └── CommentViewModel.swift
└── post_detail/
    ├── PostDetailView.swift
    └── PostDetailViewModel.swift
```

## Dependency Graph

```text
InstagramRootView binding
└── InitViewModel(currentUserID)
    ├── UserViewModel(currentUserID)
    │   └── UserRepository ───────────────┐
    └── PostFeedViewModel(currentUserID)  │
        └── PostRepository ───────────────┤
                                          └── InstagramAPI

PostDetailView binding
└── PostDetailViewModel(postID, currentUserID)
    ├── PostRepository (shared with Feed)
    └── CommentViewModel(postID, currentUserID)
        ├── UserViewModel (shared with startup flow)
        └── CommentRepository ── InstagramAPI (same instance)
```

## Key Design Decisions

- The API, repositories, feature state, and startup coordinator are managed
  ViewModels. Data entities remain immutable Swift value types.
- Every spec is stable and declared beside the module it constructs. Normal
  dependency resolution always keeps the spec and calls `read(spec)` or
  `watch(spec)`; the example never uses cached lookup.
- Identity-bearing modules receive context explicitly. Parameterized specs
  derive keys from `userID` and `postID`, so separate users and posts cannot
  collide.
- Repositories stay context-free. IDs are method arguments rather than mutable
  repository fields.
- API and repository modules use explicit keys because independent SwiftUI
  root bindings intentionally share them. They do not use `aliveForever`;
  ownership from the active root and dependency graph is sufficient.
- `PostDetailViewModel` watches `CommentViewModel` because comment state must
  propagate through the parent and refresh the detail view. Command-only
  dependencies use `read`.
- Every nested ViewModel is exposed through a computed resolver property. No
  dependency is stored in `lazy var` or another long-lived field.
- SwiftUI views use `@WatchViewModel` for broad state updates. Leaving a view
  releases its binding, then the parent generation releases its dependency
  subtree when no other owner remains.
- All ViewModel work is main-actor isolated. Async API calls suspend without
  moving state mutation away from `@MainActor`.

## Suggested Reading Order

1. Start with `app/InitViewModel.swift` to see startup coordination.
2. Follow its computed properties into the user and feed modules.
3. Open `post_detail/PostDetailViewModel.swift` to see a watched child module.
4. Compare the two SwiftUI roots to see keyed sharing across bindings.
