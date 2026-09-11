import AppKit
import SwiftUI

struct ConflictResolutionSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    let request: ConflictRequest
    let initialSize: CGSize
    @State private var parentSize: CGSize?
    private var panelSize: CGSize { parentSize ?? initialSize }
    @StateObject private var editing = ConflictEditingSession()
    @State private var activeRequest: ConflictRequest?
    @State private var document: ConflictDocument?
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var confirmClose = false
    @State private var pendingResolution: ConflictResolution?
    @State private var showResolutionConfirmation = false
    @State private var continueToNext = false
    @State private var scrollLine: CGFloat = 0
    @State private var comparison: ConflictComparison?
    @State private var comparisonText = ""
    private var currentRequest: ConflictRequest { activeRequest ?? request }
    private var ready: Bool { editing.remaining == 0 && !MergeChunk.containsMarkers(editing.text) }
    private var resultHint: String {
        if ready { return "可检查结果并保存" }
        if editing.remaining == 0 { return "结果仍含冲突标记，请清理后保存。" }
        return "橙色为冲突、蓝色为普通差异；点击编号可选择左右版本。"
    }
    private var hasNext: Bool { model.state?.files.contains { $0.isConflict && $0.path != currentRequest.file.path } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if loading {
                ProgressView("正在读取冲突版本…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                navigation.controlSize(.small)
                GeometryReader { geometry in
                    HSplitView {
                        side(document, left: true).frame(minWidth: 220, idealWidth: geometry.size.width * 0.28)
                        resultPane(document).frame(minWidth: 320, idealWidth: geometry.size.width * 0.44, maxWidth: .infinity)
                        side(document, left: false).frame(minWidth: 220, idealWidth: geometry.size.width * 0.28)
                    }
                }
                footer(document)
            } else { Spacer(); Button("关闭") { dismiss() } }
        }
        .padding(16)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(ConflictWindowConfigurator(initialSize: initialSize) { size in
            if parentSize != size { parentSize = size }
        }.frame(width: 0, height: 0))
        .disabled(saving)
        .interactiveDismissDisabled()
        .task { await load(currentRequest) }
        .task(id: editing.text) {
            guard let document else { return }
            let text = editing.text
            // Cancel stale work and keep line maps off the main actor while typing.
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { ConflictComparison.make(result: text, document: document) }
            let value = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, editing.text == text, self.document?.request.id == document.request.id else { return }
            comparison = value; comparisonText = text
        }
        .alert("放弃本次编辑？", isPresented: $confirmClose) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃编辑", role: .destructive) { dismiss() }
        } message: { Text("尚未保存的合并结果会丢失，工作区文件保持不变。") }
        .alert("确认解决此文件？", isPresented: $showResolutionConfirmation) {
            Button("取消", role: .cancel) { pendingResolution = nil }
            Button("确认") { if let pendingResolution { save(pendingResolution, next: continueToNext) } }
        } message: {
            Text("此操作作用于整个文件，并覆盖当前面板中的编辑。使用所选一侧的完整版本；若该侧不存在文件，则采用删除。确认后保存并暂存。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("解决冲突", systemImage: "arrow.triangle.merge").font(.title2.weight(.semibold))
                Text(currentRequest.file.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
            }
            if currentRequest.expected.operation == "变基" {
                Text("左侧：目标分支及已重放内容；右侧：正在重放的提交。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var navigation: some View {
        HStack(spacing: 8) {
            Button { editing.move(-1) } label: { Image(systemName: "chevron.up") }
                .help("上一处冲突或差异").disabled(editing.selected?.id == editing.blocks.first?.id)
            Button { editing.move(1) } label: { Image(systemName: "chevron.down") }
                .help("下一处冲突或差异").disabled(editing.selected?.id == editing.blocks.last?.id)
            if !editing.blocks.isEmpty {
                Menu {
                    ForEach(editing.blocks) { c in
                        Button("\(c.title) · \(c.status)") { editing.select(c.id) }
                    }
                } label: { Text(editing.selected?.title ?? "选择冲突或差异") }
                Text("冲突已处理 \(editing.conflicts.count - editing.remaining)/\(editing.conflicts.count) · 普通差异 \(editing.blocks.count - editing.conflicts.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { editing.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editing.history.canUndo).keyboardShortcut("z", modifiers: .command).help("撤销 ⌘Z")
            Button { editing.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editing.history.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help("重做 ⇧⌘Z")
        }
    }
    private func side(_ document: ConflictDocument, left: Bool) -> some View {
        let stage = left ? document.ours : document.theirs
        let map = left ? comparison?.ours : comparison?.theirs
        return VStack(alignment: .leading, spacing: 6) {
            Text(left ? "当前版本 · 只读" : "传入版本 · 只读").font(.caption.weight(.semibold))
            Text(left ? document.oursLabel : document.theirsLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).frame(height: 28, alignment: .topLeading)
            code(stage?.text ?? (stage == nil ? "此侧不存在文件（删除）" : "此版本无法预览文本"),
                 map: map, left: left)
        }.padding(.horizontal, 6)
    }
    private func resultPane(_ document: ConflictDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(document.canEdit ? "合并结果 · 可编辑" : "合并结果").font(.caption.weight(.semibold))
                Spacer()
                if let selected = editing.selected {
                    Text("\(selected.title) · \(selected.status)").font(.caption).foregroundStyle(.secondary)
                    if selected.isConflict, selected.choice == .unresolved {
                        Button("确认手动处理") { editing.markManual(selected.id) }
                            .controlSize(.small)
                            .disabled(MergeChunk.containsMarkers((editing.text as NSString).substring(with: selected.range)))
                    }
                }
            }
            Text(resultHint)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .topLeading)
            if document.canEdit {
                ConflictCodeScrollView(text: editing.text, editing: editing, scrollLine: $scrollLine,
                    synchronized: comparisonText == editing.text,
                    navigation: editing.navigation, selectedRange: editing.selected?.range,
                    conflictRanges: editing.conflicts.filter { $0.choice == .unresolved }.map(\.range),
                    changedLines: comparisonText == editing.text ? (comparison?.ours.resultChanges ?? []).union(comparison?.theirs.resultChanges ?? []) : [],
                    changeColor: .systemBlue,
                    decorations: editing.blocks.map { decoration($0, range: $0.range) },
                    selectedID: editing.selected?.id,
                    onSelect: { editing.select($0) },
                    acceptLeft: { editing.accept($0, choice: .left) })
                    .background(GitStrideStyle.input, in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(document.canSelectSide ? "此文件无法在此编辑文本，请选择完整左侧或右侧版本。" : "此文件类型无法在此面板中解决。")
                    .font(.callout).foregroundStyle(.secondary).padding()
                Spacer()
            }
        }.padding(.horizontal, 6)
    }
    private func code(_ text: String, map: ConflictLineMap?, left: Bool) -> some View {
        let usable = comparisonText == editing.text ? map : nil
        return ConflictCodeScrollView(text: text, scrollLine: $scrollLine,
            synchronized: usable != nil, lineMap: usable,
            navigation: editing.navigation,
            selectedRange: editing.selected.flatMap { sourceRange($0, text: text, map: usable, left: left) },
            conflictRanges: editing.conflicts.filter { $0.choice == .unresolved }.compactMap { mappedRange($0.range, text: text, map: usable) },
            changedLines: usable?.sourceChanges ?? [], changeColor: .systemBlue,
            decorations: editing.blocks.compactMap { block in
                sourceRange(block, text: text, map: usable, left: left).map { decoration(block, range: $0) }
            }, selectedID: editing.selected?.id, onSelect: { editing.select($0) },
            acceptRight: left ? nil : { editing.accept($0, choice: .right) })
            .background(GitStrideStyle.input, in: RoundedRectangle(cornerRadius: 8))
    }
    private func decoration(_ block: EditableConflict, range: NSRange) -> ConflictCodeDecoration {
        ConflictCodeDecoration(id: block.id, range: range,
            title: block.title + (block.isConflict && block.choice != .unresolved ? " ✓" : ""), isConflict: block.isConflict, canReplace: block.canReplace,
            showsAdoptionActions: block.choice != .left && block.choice != .right)
    }
    private func sourceRange(_ block: EditableConflict, text: String, map: ConflictLineMap?, left: Bool) -> NSRange? {
        if let range = left ? block.leftRange : block.rightRange { return range }
        return mappedRange(block.range, text: text, map: map)
    }
    private func mappedRange(_ range: NSRange?, text: String, map: ConflictLineMap?) -> NSRange? {
        guard let range, let map else { return nil }
        let mapped = map.sourceRange(forResult: range)
        let start = min(mapped.location, (text as NSString).length)
        return NSRange(location: start, length: min(mapped.length, (text as NSString).length - start))
    }

    private func footer(_ document: ConflictDocument) -> some View {
        HStack {
            Text("整个文件：").font(.caption).foregroundStyle(.secondary)
            Button("采用左侧") { confirm(.ours) }
                .disabled(!document.canSelectSide)
                .help(document.ours == nil ? "采用左侧的文件删除并暂存" : "用完整左侧版本替换文件并暂存")
            Button("采用右侧") { confirm(.theirs) }
                .disabled(!document.canSelectSide)
                .help(document.theirs == nil ? "采用右侧的文件删除并暂存" : "用完整右侧版本替换文件并暂存")
            if !document.canEdit {
                Toggle("保存后处理下一个", isOn: $continueToNext).disabled(!hasNext)
            }
            Spacer()
            Button("取消") { if editing.text != original { confirmClose = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
            if document.canEdit {
                Button(hasNext ? "保存并处理下一个" : "完成") { save(.edited(editing.text), next: true) }
                    .buttonStyle(.borderedProminent).disabled(!ready)
            }
        }
    }
    private func confirm(_ resolution: ConflictResolution) { pendingResolution = resolution; showResolutionConfirmation = true }
    @MainActor private func load(_ request: ConflictRequest) async {
        loading = true; error = nil; comparison = nil; comparisonText = ""; scrollLine = 0
        do {
            let value = try await model.git.conflictDocument(request)
            guard !Task.isCancelled else { return }
            let text = value.initialText
            let prepared = await Task.detached(priority: .userInitiated) {
                let comparison = ConflictComparison.make(result: text, document: value)
                return (comparison, EditableConflict.make(document: value, comparison: comparison))
            }.value
            guard !Task.isCancelled else { return }
            activeRequest = request; document = value; original = text
            editing.load(text, blocks: prepared.1)
            comparison = prepared.0; comparisonText = text
        } catch { self.error = error.localizedDescription; document = nil }
        loading = false
    }
    private func save(_ resolution: ConflictResolution, next: Bool) {
        guard let document else { return }
        saving = true; error = nil
        Task {
            do {
                try await model.resolveConflict(document, resolution: resolution)
                if next, let state = model.state, let file = state.files.first(where: \.isConflict) {
                    await load(ConflictRequest(expected: state, file: file))
                } else { dismiss() }
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
