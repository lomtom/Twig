import SwiftUI

struct ConflictRequest: Identifiable {
    let id = UUID()
    let expected: RepositorySnapshot
    let file: ChangedFile
}

struct ConflictStage: Equatable {
    let number: Int
    let mode: String
    let oid: String
    let data: Data?
    var text: String? {
        guard let data, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ConflictDocument {
    let request: ConflictRequest
    let stages: [ConflictStage]
    let worktree: Data?
    let symbolicLink: String?
    var ours: ConflictStage? { stages.first { $0.number == 2 } }
    var theirs: ConflictStage? { stages.first { $0.number == 3 } }
    var base: ConflictStage? { stages.first { $0.number == 1 } }
    var canEdit: Bool {
        symbolicLink == nil && stages.allSatisfy { $0.mode.hasPrefix("100") && $0.text != nil } &&
        (worktree == nil || (worktree!.count <= 2_000_000 && !worktree!.contains(0) && String(data: worktree!, encoding: .utf8) != nil))
    }
    var canSelectSide: Bool { stages.allSatisfy { $0.mode.hasPrefix("100") || $0.mode == "120000" } }
    var initialText: String {
        guard canEdit else { return "" }
        return worktree.flatMap { String(data: $0, encoding: .utf8) } ?? ours?.text ?? theirs?.text ?? ""
    }
}

enum ConflictResolution {
    case edited(String), ours, theirs, workingTree
}

/// Keeps line endings and non-conflicting edits intact, including diff3 markers.
struct MergeChunk: Identifiable {
    let range: Range<String.Index>
    let ours: String
    let theirs: String
    let id: Int

    static func parse(_ text: String) -> [MergeChunk] {
        var lines: [(Range<String.Index>, String)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            lines.append((cursor..<end, String(text[cursor..<end])))
            cursor = end
        }
        var result: [MergeChunk] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].1
            let markerSize = line.prefix(while: { $0 == "<" }).count
            guard markerSize >= 7 else { i += 1; continue }
            let start = i
            var base: Int?, separator: Int?, end: Int?
            i += 1
            while i < lines.count {
                if lines[i].1.hasPrefix(String(repeating: "|", count: markerSize)) { base = i }
                if lines[i].1.trimmingCharacters(in: .newlines) == String(repeating: "=", count: markerSize) { separator = i }
                if lines[i].1.hasPrefix(String(repeating: ">", count: markerSize)) { end = i; break }
                i += 1
            }
            if let separator, let end, start < separator, separator < end {
                let oursEnd = base ?? separator
                guard oursEnd > start, oursEnd <= separator else { i += 1; continue }
                result.append(MergeChunk(range: lines[start].0.lowerBound..<lines[end].0.upperBound,
                                         ours: lines[(start + 1)..<oursEnd].map(\.1).joined(),
                                         theirs: lines[(separator + 1)..<end].map(\.1).joined(), id: result.count))
            }
            i += 1
        }
        return result
    }
    static func containsMarkers(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.hasPrefix("<<<<<<<") || line.hasPrefix(">>>>>>>") || line.hasPrefix("|||||||") || line == "======="
        }
    }
}

struct ConflictOperationBanner: View {
    @EnvironmentObject private var model: RepositoryModel
    let state: RepositorySnapshot
    private var conflicts: [ChangedFile] { state.files.filter(\.isConflict) }
    var body: some View {
        HStack(spacing: 12) {
            Label(state.operation.map { "正在\($0)" } ?? "存在合并冲突", systemImage: "exclamationmark.triangle.fill")
            Text(conflicts.isEmpty ? "所有冲突已解决，可继续操作" : "\(conflicts.count) 个文件待解决").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let first = conflicts.first {
                Button("Resolve Conflicts…") { model.openConflict(first) }.disabled(model.busy)
            }
            if state.operation != nil {
                Button("Continue") { model.requestGraphSequence(abort: false) }.disabled(model.busy || !conflicts.isEmpty)
                if state.operation == "变基" || state.operation == "挑选提交" {
                    Button("Skip Commit…") { model.requestSkipSequence() }.disabled(model.busy)
                }
                Button("Abort…", role: .destructive) { model.requestGraphSequence(abort: true) }.disabled(model.busy)
            }
        }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(Color.orange.opacity(0.10))
    }
}

struct ConflictResolutionSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    let request: ConflictRequest
    @State private var document: ConflictDocument?
    @State private var result = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var showBase = false
    @State private var confirmClose = false
    @State private var pendingResolution: ConflictResolution?
    @State private var showResolutionConfirmation = false
    private var chunks: [MergeChunk] { MergeChunk.parse(result) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Resolve Conflicts", systemImage: "arrow.triangle.merge").font(.title2.weight(.semibold))
                Text(request.file.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Toggle("Show Common Ancestor", isOn: $showBase).toggleStyle(.button).disabled(document == nil)
            }
            if request.expected.operation == "变基" {
                Text("变基时，当前版本是目标分支及已重放的提交；传入版本是正在重放的提交。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if loading { ProgressView("正在读取冲突版本…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let document {
                if showBase {
                    side("共同祖先", stage: document.base).frame(height: 130)
                }
                HStack(alignment: .top, spacing: 10) {
                    side("当前版本 · Ours", stage: document.ours)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("合并结果").fontWeight(.medium)
                            Spacer()
                            Text("\(chunks.count) 处冲突").foregroundStyle(.secondary)
                        }.font(.caption)
                        if document.canEdit {
                            TextEditor(text: $result).font(.system(size: 12, design: .monospaced))
                                .scrollContentBackground(.hidden).padding(6)
                                .background(GitStrideStyle.input, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("合并结果")
                        } else {
                            Text("二进制、大文件、符号链接或子模块无法在此编辑文本。可选择完整一侧，或在外部编辑后标记为已解决。")
                                .font(.callout).foregroundStyle(.secondary).padding()
                            Spacer()
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    side("传入版本 · Theirs", stage: document.theirs)
                }.frame(maxHeight: .infinity)
                if document.canEdit && !chunks.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(chunks) { chunk in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("冲突 \(chunk.id + 1)").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Use Current") { replace(chunk, with: chunk.ours) }
                                        Button("Use Incoming") { replace(chunk, with: chunk.theirs) }
                                        Button("Use Both") { replace(chunk, with: chunk.ours + chunk.theirs) }
                                    }.controlSize(.small)
                                }.padding(9).background(GitStrideStyle.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.frame(height: 72)
                }
                HStack {
                    Button(document.ours == nil ? "采用当前侧删除" : "采用整个当前版本") { confirm(.ours) }.disabled(!document.canSelectSide)
                    Button(document.theirs == nil ? "采用传入侧删除" : "采用整个传入版本") { confirm(.theirs) }.disabled(!document.canSelectSide)
                    if !document.canEdit {
                        Button("Mark Working Tree File Resolved") { confirm(.workingTree) }
                    }
                    Spacer()
                    Button("取消") { close() }.keyboardShortcut(.cancelAction)
                    if document.canEdit {
                        Button("Save and Mark Resolved") { save(.edited(result)) }.buttonStyle(.borderedProminent)
                            .disabled(MergeChunk.containsMarkers(result))
                    }
                }
            } else {
                Spacer()
                HStack { Spacer(); Button("关闭") { dismiss() } }
            }
        }.padding(22).frame(width: 1020, height: 700).disabled(saving)
            .interactiveDismissDisabled()
            .task { await load() }
            .alert("放弃本次编辑？", isPresented: $confirmClose) {
                Button("继续编辑", role: .cancel) { }
                Button("放弃编辑", role: .destructive) { dismiss() }
            } message: { Text("尚未保存的合并结果会丢失，工作区文件保持不变。") }
            .alert("确认解决此文件？", isPresented: $showResolutionConfirmation) {
                Button("取消", role: .cancel) { pendingResolution = nil }
                Button("确认") { if let pendingResolution { save(pendingResolution) } }
            } message: { Text("所选完整版本将替换工作区文件并暂存；若该侧不存在文件，将采用删除。选择工作区版本时会直接暂存当前文件。") }
    }
    private func side(_ title: String, stage: ConflictStage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium))
            ScrollView([.horizontal, .vertical]) {
                Text(stage == nil ? "此侧不存在文件（删除）" : (stage?.text ?? "二进制、非 UTF-8 或超过 2 MB"))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(8)
            }.defaultScrollAnchor(.topLeading)
                .background(GitStrideStyle.input, in: RoundedRectangle(cornerRadius: 8))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func replace(_ chunk: MergeChunk, with value: String) { result.replaceSubrange(chunk.range, with: value) }
    private func confirm(_ resolution: ConflictResolution) { pendingResolution = resolution; showResolutionConfirmation = true }
    private func close() { if result != original { confirmClose = true } else { dismiss() } }
    @MainActor private func load() async {
        do {
            let value = try await model.git.conflictDocument(request)
            guard !Task.isCancelled else { return }
            document = value; result = value.initialText; original = result
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func save(_ resolution: ConflictResolution) {
        guard let document else { return }
        saving = true; error = nil
        Task {
            do {
                try await model.resolveConflict(document, resolution: resolution)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
