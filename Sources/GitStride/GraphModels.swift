import Foundation

enum GraphScope: String, CaseIterable, Identifiable {
    case currentBranch = "当前分支"
    case allBranches = "所有分支"
    var id: String { rawValue }
}

enum GraphSort: String, CaseIterable, Identifiable {
    case topology = "拓扑排序"
    case time = "时间排序"
    var id: String { rawValue }
    // Both modes keep parents below children so all graph edges remain valid.
    var argument: String { self == .topology ? "--topo-order" : "--author-date-order" }
}

struct GraphReference: Identifiable, Hashable {
    enum Kind: Hashable { case head, local, remote, tag }
    let name: String
    let kind: Kind
    var id: String { "\(kind)-\(name)" }
}

struct GraphCommit: Identifiable, Hashable {
    let oid: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    let body: String
    let references: [GraphReference]
    var id: String { oid }
    var shortOID: String { String(oid.prefix(7)) }
}

struct GraphPage {
    let commits: [GraphCommit]
    let hasMore: Bool
    let isShallow: Bool
    var currentUserEmail: String? = nil
}

struct GraphChangedFile: Identifiable, Hashable {
    let status: String
    let path: String
    let previousPath: String?
    var id: String { path }
    var label: String {
        switch status.first {
        case "A": return "新增"
        case "D": return "删除"
        case "R": return "重命名"
        default: return "修改"
        }
    }
}

struct GraphLaneRow: Identifiable {
    let commit: GraphCommit
    let lane: Int
    let nodeColor: Int
    let segments: [GraphLaneSegment]
    let arrows: [GraphLaneArrow]
    var id: String { commit.id }
}

struct GraphLaneArrow {
    let lane: Int
    let color: Int
    let pointsDown: Bool
}

struct GraphLaneSegment {
    let from: Double
    let to: Double
    let color: Int
    let half: Half
    enum Half { case incoming, outgoing }
}
