import SwiftUI

struct StashWorkspaceView: View {
    @EnvironmentObject private var model: RepositoryModel
    @State private var entries: [StashEntry] = []
    @State private var selectedID: String?
    @State private var files: [StashFile] = []
    @State private var focusedFileID: String?
    @State private var preview: SourcePreview?
    @State private var loadingList = true
    @State private var loadingFiles = false
    @State private var loadingPreview = false
    @State private var listError: String?
    @State private var detailError: String?

    private var selected: StashEntry? { entries.first { $0.id == selectedID } }
    private var focusedFile: StashFile? { files.first { $0.id == focusedFileID } }
    private var listKey: String { (model.state?.root.path ?? "") + model.stashRevision.uuidString }
    private var detailKey: String { listKey + (selectedID ?? "") }
    private var previewKey: String { detailKey + (focusedFileID ?? "") }
    private var canRestore: Bool {
        !model.busy && !loadingList && selected != nil && model.state?.operation == nil
            && model.state?.files.contains(where: \.isConflict) == false
    }
    var body: some View {
        GeometryReader { geometry in
            let listWidth = min(390, max(300, geometry.size.width * 0.30))
            HStack(spacing: 10) {
                stashSidebar
                    .frame(width: listWidth)
                    .frame(maxHeight: .infinity)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dashboardPanel()
            }.padding(10)
        }
        .background(GitStrideStyle.canvas)
        .task(id: listKey) { await loadList() }
        .task(id: detailKey) { await loadFiles() }
        .task(id: previewKey) { await loadPreview() }
    }

    private var stashSidebar: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("暂存记录").fontWeight(.medium)
                    Spacer()
                    CountBadge(value: entries.count)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                if loadingList { ProgressView("正在读取 Stash…").frame(maxWidth: .infinity).padding(20) }
                if let listError { Text(listError).font(.callout).foregroundStyle(.secondary).padding(12) }
                ForEach(entries) { entry in
                    Button { selectedID = entry.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "archivebox")
                                Text(entry.reference).font(.system(size: 11, weight: .medium, design: .monospaced))
                                Spacer()
                                Text(entry.date.formatted(date: .numeric, time: .omitted)).font(.system(size: 9))
                            }.foregroundStyle(.secondary)
                            Text(entry.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(entry.id == selectedID ? GitStrideStyle.selection : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !loadingList && entries.isEmpty && listError == nil {
                    Text("暂无暂存记录").font(.callout).foregroundStyle(.secondary).padding(16)
                }
                    }.padding(.horizontal, 8)
                }
            }.frame(minHeight: 150, idealHeight: 260, maxHeight: 330)
                .dashboardPanel()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("暂存文件").fontWeight(.medium)
                    Spacer()
                    CountBadge(value: files.count)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                if loadingFiles {
                    ProgressView("正在读取文件…").frame(maxWidth: .infinity).padding(18)
                } else if selected == nil {
                    Text("选择一条暂存记录").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18)
                } else if let detailError {
                    Text(detailError).font(.caption).foregroundStyle(.secondary).padding(18)
                } else if files.isEmpty {
                    Text("无文件").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18)
                } else {
                    PreviewFileTreeView(
                        files: files.map(\.change),
                        focusedFileID: Binding(
                            get: { files.first { $0.id == focusedFileID }?.change.path },
                            set: { path in focusedFileID = files.first { $0.change.path == path }?.id }
                        )
                    )
                }
            }.frame(maxHeight: .infinity, alignment: .top)
                .dashboardPanel()
            stashActions
        }
    }

    private var stashActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state?.files.contains(where: \.isConflict) == true || model.state?.operation != nil {
                Label("请先解决当前冲突或完成 Git 操作", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { if let selected { model.requestStashAction(selected, action: .apply) } } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(!canRestore)
                Button { if let selected { model.requestStashAction(selected, action: .pop) } } label: {
                    Label("恢复后删除", systemImage: "tray.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.bordered).disabled(!canRestore)
            }
            Button(role: .destructive) { if let selected { model.requestStashAction(selected, action: .drop) } } label: {
                Label("删除暂存记录", systemImage: "trash")
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.bordered).disabled(model.busy || loadingList || selected == nil)
        }.font(.system(size: 12)).lineLimit(1).padding(14)
            .dashboardPanel(fill: GitStrideStyle.panelHeader)
    }

    @ViewBuilder private var detail: some View {
        if selected == nil {
            VStack(spacing: 18) {
                Image(systemName: "archivebox")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(GitStrideStyle.accent)
                VStack(spacing: 8) {
                    Text("还没有搁置的改动").font(.title3).fontWeight(.medium)
                    Text("在 Commit 中勾选想暂时搁置的文件，点击文件列表顶部的存档按钮，填写说明后即可创建 Stash。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 410)
                }
                Button {
                    model.requestedDestination = .commit
                } label: {
                    Label("前往 Commit 创建 Stash", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detailError {
            ContentUnavailableView("无法读取暂存内容", systemImage: "exclamationmark.triangle", description: Text(detailError))
        } else if let focusedFile, let preview {
            SourceFileView(preview: preview, file: focusedFile.change, moveFile: movePreviewFile)
                .overlay(alignment: .topTrailing) { if loadingPreview { ProgressView().controlSize(.small).padding(14) } }
        } else if loadingFiles || loadingPreview {
            ProgressView("正在读取暂存内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("没有文件差异", systemImage: "doc.text", description: Text("选择一个文件查看暂存的改动。"))
        }
    }

    private func movePreviewFile(_ step: Int) {
        let ordered = ChangeTreeNode.build(files.map(\.change)).flatMap(\.files)
        guard let path = focusedFile?.change.path, let index = ordered.firstIndex(where: { $0.path == path }) else { return }
        let next = ordered[min(max(index + step, 0), ordered.count - 1)].path
        focusedFileID = files.first { $0.change.path == next }?.id
    }

    @MainActor private func loadList() async {
        guard let root = model.state?.root else { return }
        let oldOID = selected?.oid
        loadingList = true
        listError = nil
        do {
            let result = try await model.git.listStashes(root: root)
            guard !Task.isCancelled else { return }
            entries = result
            selectedID = result.first(where: { $0.id == selectedID })?.id ?? result.first(where: { $0.oid == oldOID })?.id ?? result.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            entries = []; selectedID = nil
            listError = error.localizedDescription
        }
        loadingList = false
    }

    @MainActor private func loadFiles() async {
        files = []; focusedFileID = nil; preview = nil; detailError = nil
        guard let entry = selected, let root = model.state?.root else { loadingFiles = false; return }
        loadingFiles = true
        do {
            let result = try await model.git.stashFiles(entry, root: root)
            guard !Task.isCancelled else { return }
            files = result
            focusedFileID = result.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
        loadingFiles = false
    }

    @MainActor private func loadPreview() async {
        guard let entry = selected, let file = focusedFile, let root = model.state?.root else { preview = nil; loadingPreview = false; return }
        loadingPreview = true
        do {
            let result = try await model.git.stashPreview(file, entry: entry, root: root)
            guard !Task.isCancelled else { return }
            preview = result
        } catch {
            guard !Task.isCancelled else { return }
            preview = .message("读取失败：\(error.localizedDescription)")
        }
        loadingPreview = false
    }
}
