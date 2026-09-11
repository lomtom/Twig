import Foundation

struct GitEnvironmentStatus: Equatable, Sendable {
    let gitAvailable: Bool
    let authorNameConfigured: Bool
    let authorEmailConfigured: Bool

    var isReadyToCommit: Bool {
        gitAvailable && authorNameConfigured && authorEmailConfigured
    }
}

struct ChangedFile: Identifiable, Hashable {
    let path: String
    let previousPath: String?
    let index: Character
    let worktree: Character
    var id: String { path }
    var isUntracked: Bool { index == "?" }
    var isConflict: Bool {
        index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
    }
    var status: String {
        if isConflict { return "Conflict" }
        if isUntracked || index == "A" || worktree == "A" { return "Added" }
        if index == "D" || worktree == "D" { return "Deleted" }
        if index == "R" || worktree == "R" { return "Renamed" }
        return "Modified"
    }
    var commitPaths: [String] { previousPath.map { [$0, path] } ?? [path] }
}

struct RepositorySnapshot: Equatable {
    let root: URL
    let branch: String
    let localBranches: [GitBranch]
    let remoteBranches: [GitBranch]
    let remoteTags: [GitTag]
    let files: [ChangedFile]
    let ahead: Int
    let behind: Int
    let upstream: String?
    let remote: String?
    let headOID: String?
    let hasHEAD: Bool
    let detached: Bool
    let operation: String?
}
