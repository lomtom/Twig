import Foundation

struct GitBranch: Identifiable, Equatable {
    let ref: String
    let oid: String
    let name: String
    let remote: String?
    let upstream: String
    let ahead: Int
    let behind: Int
    var id: String { ref }
    var isRemote: Bool { ref.hasPrefix("refs/remotes/") }
    var upstreamDifference: String? {
        guard !isRemote, !upstream.isEmpty, ahead > 0 || behind > 0 else { return nil }
        return [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
    var upstreamName: String? {
        guard !isRemote, upstream.hasPrefix("refs/remotes/") else { return nil }
        return String(upstream.dropFirst("refs/remotes/".count))
    }
}

struct BranchTreeNode: Identifiable {
    let path: String
    let name: String
    var branch: GitBranch?
    var children: [BranchTreeNode] = []
    var id: String { path }

    static func build(_ branches: [GitBranch]) -> [BranchTreeNode] {
        var root = BranchTreeNode(path: "", name: "")
        for branch in branches {
            root.insert(branch, components: branch.name.split(separator: "/").map(String.init)[...])
        }
        root.sort()
        return root.children
    }

    private mutating func insert(_ branch: GitBranch, components: ArraySlice<String>) {
        guard let name = components.first else { return }
        let childPath = path.isEmpty ? name : path + "/" + name
        let index: Int
        if let existing = children.firstIndex(where: { $0.name == name }) { index = existing }
        else { children.append(BranchTreeNode(path: childPath, name: name)); index = children.count - 1 }
        if components.count == 1 { children[index].branch = branch }
        else { children[index].insert(branch, components: components.dropFirst()) }
    }

    private mutating func sort() {
        for index in children.indices { children[index].sort() }
        children.sort {
            if $0.children.isEmpty != $1.children.isEmpty { return !$0.children.isEmpty }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
