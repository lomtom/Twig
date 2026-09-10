import Foundation

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
        if isConflict { return "冲突" }
        if isUntracked || index == "A" || worktree == "A" { return "新增" }
        if index == "D" || worktree == "D" { return "删除" }
        if index == "R" || worktree == "R" { return "重命名" }
        return "修改"
    }
    var commitPaths: [String] { previousPath.map { [$0, path] } ?? [path] }
}

struct RepositorySnapshot: Equatable {
    let root: URL
    let branch: String
    let localBranches: [GitBranch]
    let remoteBranches: [GitBranch]
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
