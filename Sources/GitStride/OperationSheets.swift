import SwiftUI

struct GraphActionRequest: Identifiable {
    let id = UUID()
    let action: GraphCommitAction
    let commit: GraphCommit
    let expected: RepositorySnapshot
}

struct GraphActionSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    let request: GraphActionRequest
    @State private var resetMode: GraphResetMode = .mixed
    @State private var stashChanges = false
    private var action: GraphCommitAction {
        if case .reset = request.action { return .reset(resetMode) }
        return request.action
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action.title).font(.title2.weight(.semibold))
            Text("当前分支：" + request.expected.branch).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(request.commit.subject).fontWeight(.medium)
                Text(request.commit.oid).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            }
            if case .reset = request.action {
                Picker("重置类型", selection: $resetMode) {
                    ForEach(GraphResetMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.radioGroup)
            }
            Text(action.explanation).font(.callout).foregroundStyle(action.destructive ? Color.red : .secondary)
            if let parent = action.mainline {
                Text("以第 \(parent) 个父提交为主线。").font(.callout).foregroundStyle(.secondary)
            }
            if action.needsCleanTree && !request.expected.files.isEmpty {
                Toggle("先将本地改动保存到 Stash", isOn: $stashChanges)
                Text(stashChanges ? "包含未跟踪文件。操作结束后保留 Stash，可从暂存区恢复。" : "Git 会检查本地改动；如有覆盖风险或索引不干净，会停止操作。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认 " + action.title, role: action.destructive ? .destructive : nil) {
                    model.executeGraphCommitAction(request, action: action, stashChanges: stashChanges)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.padding(24).frame(width: 510)
    }
}

struct PushReviewRequest: Identifiable {
    let id = UUID()
    let expected: RepositorySnapshot
    var message: String? = nil
    var paths: [String] = []
    var destination: String { expected.upstream ?? (expected.remote ?? "远程") + "/" + expected.branch }
}

struct PushReviewSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    let request: PushReviewRequest
    @State private var commits: [GraphCommit] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.message == nil ? "确认推送" : "确认提交并推送").font(.title2.weight(.semibold))
            Text(request.expected.branch + " → " + request.destination).font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("正在读取待推送提交…").frame(maxWidth: .infinity).padding() }
            else if let error { Text(error).foregroundStyle(.red) }
            else {
                HStack {
                    Text("待推送提交").fontWeight(.medium)
                    Spacer()
                    CountBadge(value: commits.count + (request.message == nil ? 0 : 1))
                }.font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let message = request.message {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(message, systemImage: "plus.circle.fill").fontWeight(.medium)
                                Text("即将创建 · \(request.paths.count) 个路径").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                        ForEach(commits) { commit in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(commit.subject).font(.callout).textSelection(.enabled)
                                Text("\(commit.shortOID) · \(commit.author) · \(commit.date.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if commits.isEmpty && request.message == nil { Text("没有待推送提交").foregroundStyle(.secondary) }
                    }.padding(12)
                }.frame(height: min(330, max(100, CGFloat(commits.count + (request.message == nil ? 0 : 1)) * 57)))
                    .background(GitStrideStyle.subtleFill, in: RoundedRectangle(cornerRadius: 10))
                Text("根据上次获取的远程状态计算；新分支会显示其全部历史。推送前会再次检查本地分支，远程拒绝时不会强制推送。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.message == nil ? "推送" : "提交并推送") {
                    model.executePushReview(request); dismiss()
                }.buttonStyle(.borderedProminent).disabled(loading || error != nil || model.busy)
            }
        }.padding(24).frame(width: 560)
            .task {
                do {
                    let result = try await model.git.outgoingCommits(request.expected)
                    guard !Task.isCancelled else { return }
                    commits = result
                } catch { self.error = error.localizedDescription }
                loading = false
            }
    }
}
