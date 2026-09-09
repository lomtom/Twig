import Foundation

struct StashEntry: Identifiable {
    let reference: String
    let oid: String
    let message: String
    let date: Date
    var id: String { reference + ":" + oid }
}

struct StashFile: Identifiable {
    let change: ChangedFile
    let untracked: Bool
    var indexOnly = false
    var id: String { (untracked ? "untracked:" : "tracked:") + change.path }
}

enum StashAction {
    case apply, pop, drop
    var title: String {
        switch self {
        case .apply: return "恢复"
        case .pop: return "恢复并移除"
        case .drop: return "删除"
        }
    }
}
