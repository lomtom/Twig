import SwiftUI

/// All workspaces share the same folder layout and recursive file count.
struct FileTreeFolderRow<Selection: View>: View {
    let name: String
    let path: String
    let depth: Int
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void
    @ViewBuilder var selection: () -> Selection

    var body: some View {
        HStack(spacing: 7) {
            Button(action: toggle) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12, height: 18)
            }.buttonStyle(.plain).accessibilityLabel("\(collapsed ? "展开" : "折叠") \(name)")
            selection()
            Image(systemName: collapsed ? "folder.fill" : "folder").foregroundStyle(GitStrideStyle.accent)
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 2)
            CountBadge(value: count)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 2)
            .contentShape(Rectangle()).onTapGesture(count: 2, perform: toggle).help(path)
    }
}

/// File-only browser shared by historical commits and stashes.
struct PreviewFileTreeView: View {
    let files: [ChangedFile]
    @Binding var focusedFileID: String?
    @State private var collapsed = Set<String>()
    @FocusState private var keyboardFocused: Bool
    private struct Row: Identifiable {
        let node: ChangeTreeNode
        let depth: Int
        var id: String { node.id }
    }
    private var rows: [Row] {
        func flatten(_ nodes: [ChangeTreeNode], depth: Int) -> [Row] {
            nodes.flatMap { node in
                [Row(node: node, depth: depth)] + (node.file == nil && !collapsed.contains(node.path)
                    ? flatten(node.children, depth: depth + 1) : [])
            }
        }
        return flatten(ChangeTreeNode.build(files), depth: 0)
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        if let file = row.node.file {
                            Button { focusedFileID = file.id; keyboardFocused = true } label: {
                                HStack(spacing: 7) {
                                    Color.clear.frame(width: 12, height: 1)
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(row.node.name).font(.system(size: 12)).foregroundStyle(file.treeColor)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 2)
                                }.padding(.leading, CGFloat(row.depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 4)
                                    .background(focusedFileID == file.id ? GitStrideStyle.selection : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(file.previousPath.map { "\($0) → \(file.path)" } ?? file.path)
                                .id(file.id)
                        } else {
                            FileTreeFolderRow(name: row.node.name, path: row.node.path, depth: row.depth,
                                              count: row.node.files.count, collapsed: collapsed.contains(row.node.path)) {
                                if !collapsed.insert(row.node.path).inserted { collapsed.remove(row.node.path) }
                            } selection: { EmptyView() }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.focusable().focusEffectDisabled().focused($keyboardFocused)
                .onKeyPress(.upArrow) { move(-1, proxy: proxy); return .handled }
                .onKeyPress(.downArrow) { move(1, proxy: proxy); return .handled }
                .onChange(of: focusedFileID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
    private func move(_ step: Int, proxy: ScrollViewProxy) {
        let visible = rows.compactMap { $0.node.file }
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == focusedFileID } ?? (step > 0 ? -1 : visible.count)
        focusedFileID = visible[min(max(current + step, 0), visible.count - 1)].id
    }
}

extension ChangedFile {
    var treeColor: Color {
        if isUntracked { return GitStrideStyle.unversioned }
        if isConflict { return .orange }
        switch status {
        case "新增": return GitStrideStyle.added
        case "删除": return .red
        case "修改": return GitStrideStyle.modified
        case "重命名": return .orange
        default: return .secondary
        }
    }
}
