import AppKit
import SwiftUI

struct ChangeTreeView: View {
    @EnvironmentObject private var model: RepositoryModel
    let nodes: [ChangeTreeNode]
    let state: RepositorySnapshot
    @State private var collapsed = Set<String>()

    private struct Row: Identifiable {
        let node: ChangeTreeNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        func flatten(_ nodes: [ChangeTreeNode], depth: Int) -> [Row] {
            nodes.flatMap { node in
                [Row(node: node, depth: depth)] + (node.file == nil && !collapsed.contains(node.path) ? flatten(node.children, depth: depth + 1) : [])
            }
        }
        return flatten(nodes, depth: 0)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    if let file = row.node.file { fileRow(file, depth: row.depth) }
                    else { directoryRow(row.node, depth: row.depth) }
                }
        }.padding(.horizontal, 8)
            .onChange(of: model.treeExpansion.id) { _, _ in
                collapsed = model.treeExpansion.expand ? [] : directoryPaths(nodes)
            }
    }

    private func directoryPaths(_ nodes: [ChangeTreeNode]) -> Set<String> {
        Set(nodes.filter { $0.file == nil }.map(\.path)).union(nodes.reduce(into: Set<String>()) { $0.formUnion(directoryPaths($1.children)) })
    }

    private func directoryRow(_ node: ChangeTreeNode, depth: Int) -> some View {
        let paths = Set(node.files.map(\.path))
        let files = node.files
        let isUntrackedDirectory = files.allSatisfy(\.isUntracked)
        let discardableFiles = files.filter { !$0.isUntracked && $0.index != "A" && !$0.isConflict }
        let selected = paths.intersection(model.selectedPaths).count
        let isCollapsed = collapsed.contains(node.path)
        return HStack(spacing: 7) {
            Button { toggleDirectory(node.path) } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 12, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCollapsed ? "展开" : "折叠") \(node.name)")
            Toggle("选择目录 \(node.path)", sources: node.files.map { file in
                Binding<Bool>(get: { model.selectedPaths.contains(file.path) }, set: { isSelected in
                    if isSelected { model.selectedPaths.insert(file.path) }
                    else { model.selectedPaths.remove(file.path) }
                })
            }, isOn: \.self)
                .toggleStyle(.checkbox).labelsHidden().disabled(model.busy)
                .accessibilityLabel("选择目录 \(node.path)，已选 \(selected) 个文件")
            Image(systemName: isCollapsed ? "folder.fill" : "folder").foregroundStyle(GitStrideStyle.accent)
            Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 2)
            CountBadge(value: paths.count)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleDirectory(node.path) }
            .help(node.path)
            .contextMenu {
                if isUntrackedDirectory {
                    Button("添加到 Git") { model.addToGit(files) }
                        .disabled(model.busy || state.operation != nil)
                    Divider()
                }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([state.root.appendingPathComponent(node.path)]) }
                if !discardableFiles.isEmpty && state.hasHEAD && state.operation == nil {
                    Button("丢弃目录改动…", role: .destructive) { model.requestFileAction(.rollback, files: discardableFiles) }
                        .disabled(model.busy)
                }
            }
    }

    private func fileRow(_ file: ChangedFile, depth: Int) -> some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 12, height: 1)
            Toggle("提交 \(file.path)", isOn: Binding(get: { model.selectedPaths.contains(file.path) }, set: { _ in model.toggle(file.path) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(model.busy)
            Image(systemName: file.isConflict ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(file.isConflict ? Color.orange : Color.secondary)
            Text((file.path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(fileNameColor(file))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 3)
            .background(model.focusedFile == file.path ? GitStrideStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle()).onTapGesture { model.focusedFile = file.path }
            .help(file.path)
            .accessibilityElement(children: .contain).accessibilityAction(named: "查看源文件") { model.focusedFile = file.path }
            .contextMenu {
                if file.isUntracked {
                    Button("添加到 Git") { model.addToGit(file) }
                        .disabled(model.busy || state.operation != nil)
                    Divider()
                }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([state.root.appendingPathComponent(file.path)]) }
                if !file.isUntracked && file.index != "A" && state.hasHEAD && state.operation == nil && !file.isConflict {
                    Button("丢弃文件改动…", role: .destructive) { model.requestFileAction(.rollback, files: [file]) }.disabled(model.busy)
                }
            }
    }

    private func fileNameColor(_ file: ChangedFile) -> Color {
        if file.isUntracked { return GitStrideStyle.unversioned }
        if file.isConflict { return .orange }
        switch file.status {
        case "新增": return GitStrideStyle.added
        case "删除": return .red
        case "修改": return GitStrideStyle.modified
        default: return .secondary
        }
    }

    private func toggleDirectory(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) }
        else { collapsed.insert(path) }
    }
}
