import SwiftUI
import AppKit

enum GraphResetMode: String, CaseIterable, Identifiable {
    case soft, mixed, hard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .soft: return "Soft · 保留暂存区与工作区"
        case .mixed: return "Mixed · 保留工作区，取消暂存"
        case .hard: return "Hard · 丢弃本地改动"
        }
    }
}

enum GraphCommitAction {
    case reset(GraphResetMode)
    case cherryPick(Int?)
    case revert(Int?)
    case undo

    var title: String {
        switch self {
        case .reset: return "Reset to Here"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert Commit"
        case .undo: return "Undo Commit"
        }
    }
    var destructive: Bool {
        if case .reset(.hard) = self { return true }
        return false
    }
    var needsCleanTree: Bool {
        switch self { case .cherryPick, .revert: return true; default: return false }
    }
    var mainline: Int? {
        switch self { case let .cherryPick(parent), let .revert(parent): return parent; default: return nil }
    }
    var explanation: String {
        switch self {
        case .reset(.soft): return "将当前分支移动到此提交；暂存区和工作区保持不变。该操作会改写当前分支的本地历史。"
        case .reset(.mixed): return "将当前分支移动到此提交；工作区保留，暂存区重置。该操作会改写当前分支的本地历史。"
        case .reset(.hard): return "将当前分支、暂存区和工作区重置到此提交。未提交的已跟踪改动会丢失，阻挡检出路径的未跟踪文件也可能被删除。已推送的远程分支不会改变。"
        case .cherryPick: return "将此提交的改动应用到当前分支并创建新提交。发生冲突时会保留现场，可解决并暂存冲突后继续，也可以中止。"
        case .revert: return "在当前分支创建一个反向提交，撤销此提交引入的改动，不删除已有历史。发生冲突时可解决后继续或中止。"
        case .undo: return "撤销当前 HEAD 提交，将分支移至其第一父提交，改动保留在暂存区（Soft Reset）。已有暂存改动也会保留；远程历史不会改变。"
        }
    }
}

struct GraphCommitContextMenu: View {
    @EnvironmentObject private var model: RepositoryModel
    let commit: GraphCommit

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    var body: some View {
        Section("复制") {
            Button("Copy Commit ID") { copy(commit.oid) }
            Button("Copy Short Commit ID") { copy(commit.shortOID) }
            Button("复制提交信息") { copy(commit.body.isEmpty ? commit.subject : commit.body) }
        }
        Section("查看") {
            Button("查看提交详情") { model.selectGraphCommit(commit) }
        }
        Section("应用提交") {
            if commit.parents.count > 1 {
                Menu("Cherry-pick…") {
                    ForEach(commit.parents.indices, id: \.self) { parent in
                        action("相对父提交 \(parent + 1) · \(commit.parents[parent].prefix(7))", .cherryPick(parent + 1))
                    }
                }.disabled(!model.canApplyGraphCommit)
                Menu("Revert Commit…") {
                    ForEach(commit.parents.indices, id: \.self) { parent in
                        action("相对父提交 \(parent + 1) · \(commit.parents[parent].prefix(7))", .revert(parent + 1))
                    }
                }.disabled(!model.canApplyGraphCommit)
            } else {
                action("Cherry-pick…", .cherryPick(nil)).disabled(!model.canApplyGraphCommit)
                action("Revert Commit…", .revert(nil)).disabled(!model.canApplyGraphCommit)
            }
        }
        Section("移动分支") {
            action("Reset to Here…", .reset(.mixed)).disabled(!model.canModifyGraphHistory)
            action("Undo Commit · 保留改动…", .undo)
                .disabled(!model.canModifyGraphHistory || commit.oid != model.state?.headOID || commit.parents.isEmpty)
        }
        if let operation = model.state?.operation, ["挑选提交", "撤销提交"].contains(operation) {
            Section("进行中的\(operation)") {
                Button("继续\(operation)…") { model.requestGraphSequence(abort: false) }
                    .disabled(model.busy || model.state?.files.contains(where: \.isConflict) == true)
                Button("中止\(operation)…", role: .destructive) { model.requestGraphSequence(abort: true) }
                    .disabled(model.busy)
                Button("在终端打开仓库") { model.openTerminal() }
            }
        }
    }
    private func action(_ title: String, _ action: GraphCommitAction) -> some View {
        Button(title, role: action.destructive ? .destructive : nil) {
            model.requestGraphCommitAction(action, commit: commit)
        }
    }
}
