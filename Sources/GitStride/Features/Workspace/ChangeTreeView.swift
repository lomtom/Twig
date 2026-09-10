import AppKit
import SwiftUI

struct ChangeTreeView: View {
    @EnvironmentObject private var model: RepositoryModel
    let nodes: [ChangeTreeNode]
    let state: RepositorySnapshot
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
                [Row(node: node, depth: depth)] + (node.file == nil && !collapsed.contains(node.path) ? flatten(node.children, depth: depth + 1) : [])
            }
        }
        return flatten(nodes, depth: 0)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    if let file = row.node.file { fileRow(file, depth: row.depth).id(file.path) }
                    else { directoryRow(row.node, depth: row.depth) }
                }
        }.padding(.horizontal, 8)
            .focusable().focusEffectDisabled().focused($keyboardFocused)
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onChange(of: model.treeExpansion.id) { _, _ in
                collapsed = model.treeExpansion.expand ? [] : directoryPaths(nodes)
            }
    }

    private func move(_ step: Int) {
        let visible = rows.compactMap { $0.node.file }
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.path == model.focusedFile } ?? (step > 0 ? -1 : visible.count)
        model.focusedFile = visible[min(max(index + step, 0), visible.count - 1)].path
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
        return FileTreeFolderRow(name: node.name, path: node.path, depth: depth, count: paths.count,
                                 collapsed: isCollapsed, toggle: { toggleDirectory(node.path) }) {
            Toggle("选择目录 \(node.path)", sources: node.files.map { file in
                Binding<Bool>(get: { model.selectedPaths.contains(file.path) }, set: { isSelected in
                    if isSelected { model.selectedPaths.insert(file.path) }
                    else { model.selectedPaths.remove(file.path) }
                })
            }, isOn: \.self)
                .toggleStyle(.checkbox).labelsHidden().disabled(model.busy)
                .accessibilityLabel("选择目录 \(node.path)，已选 \(selected) 个文件")
        }
            .contextMenu {
                if isUntrackedDirectory {
                    Button("Add to Git") { model.addToGit(files) }
                        .disabled(model.busy || state.operation != nil)
                    Divider()
                }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.root.appendingPathComponent(node.path)]) }
                if !discardableFiles.isEmpty && state.hasHEAD && state.operation == nil {
                    Button("Discard Folder Changes", role: .destructive) { model.requestFileAction(.rollback, files: discardableFiles) }
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
                .foregroundStyle(file.treeColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
        }.padding(.leading, CGFloat(depth) * 14 + 5).padding(.trailing, 9).padding(.vertical, 3)
            .background(model.focusedFile == file.path ? GitStrideStyle.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle()).onTapGesture { model.focusedFile = file.path; keyboardFocused = true }
            .help(file.path)
            .accessibilityElement(children: .contain).accessibilityAction(named: "查看源文件") { model.focusedFile = file.path }
            .contextMenu {
                if file.isConflict {
                    Button("Resolve Conflicts") { model.openConflict(file) }.disabled(model.busy)
                    Divider()
                }
                if file.isUntracked {
                    Button("Add to Git") { model.addToGit(file) }
                        .disabled(model.busy || state.operation != nil)
                    Divider()
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.root.appendingPathComponent(file.path)]) }
                if !file.isUntracked && file.index != "A" && state.hasHEAD && state.operation == nil && !file.isConflict {
                Button("Discard File Changes", role: .destructive) { model.requestFileAction(.rollback, files: [file]) }.disabled(model.busy)
                }
            }
    }

    private func toggleDirectory(_ path: String) {
        if collapsed.contains(path) { collapsed.remove(path) }
        else { collapsed.insert(path) }
    }
}
