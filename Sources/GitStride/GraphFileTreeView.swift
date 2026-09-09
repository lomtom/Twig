import SwiftUI

private struct GraphFileTreeNode: Identifiable {
    let path: String
    let name: String
    var file: GraphChangedFile?
    var children: [GraphFileTreeNode] = []
    var id: String { (file == nil ? "directory:" : "file:") + path }

    static func build(_ files: [GraphChangedFile]) -> [GraphFileTreeNode] {
        var root = GraphFileTreeNode(path: "", name: "")
        for file in files {
            root.insert(file, components: file.path.split(separator: "/").map(String.init)[...])
        }
        root.sort()
        return root.children
    }

    private mutating func insert(_ file: GraphChangedFile, components: ArraySlice<String>) {
        guard let name = components.first else { return }
        let childPath = path.isEmpty ? name : path + "/" + name
        if components.count == 1 {
            children.append(GraphFileTreeNode(path: childPath, name: name, file: file))
            return
        }
        let index: Int
        if let existing = children.firstIndex(where: { $0.name == name && $0.file == nil }) {
            index = existing
        } else {
            children.append(GraphFileTreeNode(path: childPath, name: name))
            index = children.count - 1
        }
        children[index].insert(file, components: components.dropFirst())
    }

    private mutating func sort() {
        for index in children.indices { children[index].sort() }
        children.sort {
            if ($0.file == nil) != ($1.file == nil) { return $0.file == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct GraphFileTreeView: View {
    let files: [GraphChangedFile]
    @Binding var focusedFileID: String?
    @State private var collapsed = Set<String>()

    private struct Row: Identifiable {
        let node: GraphFileTreeNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        func flatten(_ nodes: [GraphFileTreeNode], depth: Int) -> [Row] {
            nodes.flatMap { node in
                [Row(node: node, depth: depth)] + (node.file == nil && !collapsed.contains(node.path)
                    ? flatten(node.children, depth: depth + 1) : [])
            }
        }
        return flatten(GraphFileTreeNode.build(files), depth: 0)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                if let file = row.node.file {
                    fileRow(file, name: row.node.name, depth: row.depth)
                } else {
                    directoryRow(row.node, depth: row.depth)
                }
            }
        }.padding(.horizontal, 8).padding(.bottom, 8)
    }

    private func directoryRow(_ node: GraphFileTreeNode, depth: Int) -> some View {
        let isCollapsed = collapsed.contains(node.path)
        return HStack(spacing: 7) {
            Button { toggleDirectory(node.path) } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCollapsed ? "展开" : "折叠") \(node.name)")
            Image(systemName: isCollapsed ? "folder.fill" : "folder")
                .foregroundStyle(Color.accentColor)
            Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 2)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleDirectory(node.path) }
            .help(node.path)
    }

    private func fileRow(_ file: GraphChangedFile, name: String, depth: Int) -> some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 12, height: 1)
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(fileNameColor(file))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 4)
            .background(focusedFileID == file.id ? GitStrideStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { focusedFileID = file.id }
            .help(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "选择变更文件") { focusedFileID = file.id }
    }

    private func fileNameColor(_ file: GraphChangedFile) -> Color {
        switch file.label {
        case "新增": return GitStrideStyle.added
        case "删除": return .red
        case "修改": return GitStrideStyle.modified
        case "重命名": return .orange
        default: return .secondary
        }
    }

    private func toggleDirectory(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) }
        else { collapsed.insert(path) }
    }
}
