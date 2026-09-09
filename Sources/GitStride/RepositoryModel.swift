import AppKit
import SwiftUI

@MainActor
final class RepositoryModel: ObservableObject {
    @Published var state: RepositorySnapshot?
    @Published var selectedPaths = Set<String>()
    @Published var focusedFile: String?
    @Published var sourcePreview: SourcePreview?
    @Published var loadingDiff = false
    @Published var message = ""
    @Published var busy = false
    @Published var activity = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    @Published var showClone = false
    @Published var showBranch = false
    @Published var fileAction: FileActionRequest?
    @Published var confirmation: OperationConfirmation?
    @Published var stashRevision = UUID()
    @Published var treeExpansion: (id: UUID, expand: Bool) = (UUID(), true)
    let git = GitService()
    private var diffTask: Task<Void, Never>?
    private var diffGeneration = UUID()

    var focusedChange: ChangedFile? { state?.files.first { $0.path == focusedFile } }
    var canCommit: Bool {
        !busy && !selectedPaths.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state?.operation == nil && state?.files.contains(where: \.isConflict) == false && state?.detached == false
    }
    var canCommitAndPush: Bool {
        canCommit && (state?.upstream != nil || state?.remote != nil)
    }
    var canSync: Bool { !busy && state != nil && state?.operation == nil && state?.detached == false }

    func chooseRepository() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开 Git 仓库"
        panel.prompt = "打开仓库"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        perform("正在打开仓库…") {
            let root = try await self.git.open(url)
            let snapshot = try await self.git.snapshot(root)
            self.diffTask?.cancel()
            self.diffGeneration = UUID()
            self.state = snapshot
            self.selectedPaths = []
            self.focusedFile = snapshot.files.first?.path
            self.message = ""
            self.recent.removeAll { $0 == root.path }
            self.recent.insert(root.path, at: 0)
            self.recent = Array(self.recent.prefix(8))
            UserDefaults.standard.set(self.recent, forKey: "recentRepositories")
            self.loadDiff()
        }
    }

    func refresh(fetch: Bool = false) {
        guard let root = state?.root else { return }
        perform(fetch ? "正在获取远程状态…" : "正在刷新…") {
            if fetch { try await self.git.fetch(root: root) }
            try await self.reload()
            if fetch { self.notice = "远程状态已更新" }
        }
    }

    private func reload() async throws {
        guard let old = state else { return }
        let snapshot = try await git.snapshot(old.root)
        let current = Set(snapshot.files.map(\.path))
        selectedPaths.formIntersection(current)
        state = snapshot
        stashRevision = UUID()
        if !snapshot.files.contains(where: { $0.path == focusedFile }) { focusedFile = snapshot.files.first?.path }
        loadDiff()
    }

    func loadDiff() {
        diffTask?.cancel()
        let generation = UUID()
        diffGeneration = generation
        sourcePreview = nil
        guard let snapshot = state, let file = focusedChange else { loadingDiff = false; return }
        loadingDiff = true
        diffTask = Task {
            do {
                let preview = try await git.sourcePreview(file, in: snapshot)
                guard !Task.isCancelled, diffGeneration == generation else { return }
                sourcePreview = preview
            } catch {
                guard !Task.isCancelled, diffGeneration == generation else { return }
                sourcePreview = .message("无法加载源文件：\(error.localizedDescription)")
            }
            loadingDiff = false
        }
    }

    func toggle(_ path: String) {
        if selectedPaths.contains(path) { selectedPaths.remove(path) } else { selectedPaths.insert(path) }
    }

    func addToGit(_ file: ChangedFile) {
        addToGit([file])
    }

    func addToGit(_ files: [ChangedFile]) {
        guard !busy, !files.isEmpty, files.allSatisfy(\.isUntracked), let state, state.operation == nil else { return }
        perform("正在添加到 Git…", recover: true) {
            try await self.git.addToGit(files, root: state.root)
            try await self.reload()
            self.notice = files.count == 1 ? "已添加到 Git" : "已将 \(files.count) 个文件添加到 Git"
        }
    }

    func commit() {
        guard canCommit, let state else { return }
        let paths = Array(Set(state.files.filter { selectedPaths.contains($0.path) }.flatMap(\.commitPaths))).sorted()
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("正在提交…", recover: true) {
            try await self.git.commit(paths: paths, message: commitMessage, root: state.root)
            self.message = ""
            try await self.reload()
            self.notice = "已提交到本地仓库"
        }
    }

    func commitAndPush() {
        guard canCommitAndPush, let state else { return }
        let files = selectedFiles
        let paths = Array(Set(files.flatMap(\.commitPaths))).sorted()
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = state.upstream ?? (state.remote ?? "远程") + "/" + state.branch
        confirmation = OperationConfirmation(title: "确认提交并推送？", message: "将所选 \(files.count) 个文件提交到“\(state.branch)”，然后推送到“\(destination)”。此分支已有的未推送提交也会一起推送。") { [weak self] in
            guard let self, !self.busy else { return }
            guard self.state?.root == state.root else { self.error = "仓库已切换，请重新确认。"; return }
            self.perform("正在提交…", recover: true) {
                let current = try await self.git.snapshot(state.root)
                guard current.branch == state.branch, current.headOID == state.headOID,
                      current.upstream == state.upstream, current.remote == state.remote else {
                    throw GitFailure(message: "仓库或分支状态已变化，请重新确认提交并推送。")
                }
                try await self.git.commit(paths: paths, message: commitMessage, root: state.root)
                self.message = ""
                do {
                    let committed = try await self.git.snapshot(state.root)
                    guard committed.branch == state.branch, committed.upstream == state.upstream, committed.remote == state.remote else {
                        throw GitFailure(message: "提交后分支或远程配置发生变化，请刷新后单独推送。")
                    }
                    self.activity = "正在推送…"
                    try await self.git.push(state: committed)
                } catch {
                    throw GitFailure(message: "本地提交已完成，但推送未完成。提交已保留，请处理以下问题后单独推送，无需再次提交。\n\n\(error.localizedDescription)")
                }
                try await self.reload()
                self.notice = "已提交并推送"
            }
        }
    }

    func pull() {
        guard canSync, let state else { return }
        confirmation = OperationConfirmation(title: "确认拉取？", message: "从“\(state.upstream ?? "上游")”拉取并更新当前分支和工作区，仅允许快进。") { [weak self] in 
            guard let self, self.state?.root == state.root, self.state?.branch == state.branch, self.state?.upstream == state.upstream, self.state?.headOID == state.headOID else { return }
            self.executePull() }
    }

    private func executePull() {
        guard canSync, let state else { return }
        perform("正在拉取…", recover: true) {
            try await self.git.pull(root: state.root)
            try await self.reload()
            self.notice = "拉取完成"
        }
    }

    func push() {
        guard canSync, let state else { return }
        confirmation = OperationConfirmation(title: "确认推送？", message: "将分支“\(state.branch)”的提交推送到“\(state.upstream ?? (state.remote ?? "远程") + "/" + state.branch)”。") { [weak self] in 
            guard let self, self.state?.root == state.root, self.state?.branch == state.branch, self.state?.upstream == state.upstream, self.state?.remote == state.remote, self.state?.headOID == state.headOID else { return }
            self.executePush() }
    }

    private func executePush() {
        guard canSync, let state else { return }
        perform("正在推送…", recover: true) {
            try await self.git.push(state: state)
            try await self.reload()
            self.notice = "推送完成"
        }
    }

    func switchBranch(_ name: String, create: Bool = false, confirmed: Bool = false) {
        guard !busy, let state, state.operation == nil else { return }
        if !create && !confirmed && !state.files.isEmpty {
            confirmation = OperationConfirmation(title: "带着未提交改动切换分支？", message: "将切换到“\(name)”。可保留的改动会带入目标分支；存在覆盖风险时 Git 会阻止切换。") { [weak self] in self?.switchBranch(name, confirmed: true) }
            return
        }
        let root = state.root
        perform(create ? "正在创建分支…" : "正在切换分支…", recover: true) {
            try await self.git.switchBranch(name, create: create, root: root)
            try await self.reload()
            self.notice = "当前分支：\(name)"
        }
    }

    func selectBranch(_ branch: GitBranch, confirmed: Bool = false) {
        guard branch.isRemote else { switchBranch(branch.name); return }
        guard !busy, let state, state.operation == nil else { return }
        if !confirmed && !state.files.isEmpty {
            confirmation = OperationConfirmation(title: "带着未提交改动切换分支？", message: "将切换到远程分支“\(branch.name)”对应的本地分支。可保留的改动会一起带入。") { [weak self] in self?.selectBranch(branch, confirmed: true) }
            return
        }
        perform("正在切换分支…", recover: true) {
            let name = try await self.git.switchRemoteBranch(branch, root: state.root)
            try await self.reload()
            self.notice = "当前分支：\(name)"
        }
    }

    func createBranch(from branch: GitBranch, named name: String) {
        guard !busy, !branch.isRemote, let state, state.operation == nil else { return }
        perform("正在创建分支…", recover: true) {
            try await self.git.createBranch(name, from: branch.name, root: state.root)
            try await self.reload()
            self.notice = "当前分支：\(name)"
        }
    }

    func renameBranch(_ branch: GitBranch, to name: String) {
        guard !busy, !branch.isRemote, let state, state.operation == nil else { return }
        perform("正在重命名分支…", recover: true) {
            try await self.git.renameBranch(branch.name, to: name, root: state.root)
            try await self.reload()
            self.notice = "分支已重命名为：\(name)"
        }
    }

    func deleteBranch(_ branch: GitBranch) {
        guard !busy, !branch.isRemote, let state, state.operation == nil, branch.name != state.branch else { return }
        confirmation = OperationConfirmation(title: "删除分支？", message: "将删除本地分支“\(branch.name)”。Git 会阻止删除尚未合并的分支。", destructive: true) { [weak self] in
            guard let self else { return }
            self.perform("正在删除分支…", recover: true) {
                try await self.git.deleteBranch(branch.name, root: state.root)
                try await self.reload()
                self.notice = "已删除分支：\(branch.name)"
            }
        }
    }

    func rebaseCurrentBranch(onto branch: GitBranch) {
        guard !busy, !branch.isRemote, let state, state.operation == nil, branch.name != state.branch else { return }
        confirmation = OperationConfirmation(title: "变基当前分支？", message: "将当前分支“\(state.branch)”变基到“\(branch.name)”之上。发生冲突时需手动解决后继续。") { [weak self] in
            guard let self else { return }
            self.perform("正在变基…", recover: true) {
                try await self.git.rebaseCurrentBranch(onto: branch.name, root: state.root)
                try await self.reload()
                self.notice = "已将“\(state.branch)”变基到“\(branch.name)”"
            }
        }
    }

    func mergeBranchIntoCurrent(_ branch: GitBranch) {
        guard !busy, !branch.isRemote, let state, state.operation == nil, branch.name != state.branch else { return }
        confirmation = OperationConfirmation(title: "合并分支？", message: "将“\(branch.name)”合并到当前分支“\(state.branch)”。发生冲突时需手动解决后继续。") { [weak self] in
            guard let self else { return }
            self.perform("正在合并…", recover: true) {
                try await self.git.mergeIntoCurrentBranch(branch.name, root: state.root)
                try await self.reload()
                self.notice = "已将“\(branch.name)”合并到“\(state.branch)”"
            }
        }
    }

    var selectedFiles: [ChangedFile] { state?.files.filter { selectedPaths.contains($0.path) } ?? [] }
    var canChangeFiles: Bool {
        !busy && !selectedFiles.isEmpty && state?.operation == nil && state?.files.contains(where: \.isConflict) == false
    }

    func requestFileAction(_ kind: FileActionRequest.Kind, files: [ChangedFile]? = nil) {
        guard !busy, let state, state.operation == nil else { return }
        let files = files ?? selectedFiles
        guard !files.isEmpty else { return }
        fileAction = FileActionRequest(kind: kind, root: state.root, branch: state.branch, headOID: state.headOID, files: files)
    }

    func executeFileAction(_ request: FileActionRequest, paths: Set<String>, message: String) {
        guard state?.root == request.root, state?.branch == request.branch, state?.headOID == request.headOID else {
            error = "仓库状态已变化，请重新选择文件。"; return
        }
        let files = request.files.filter { paths.contains($0.path) }
        perform(request.kind == .stash ? "正在暂存…" : "正在回滚…", recover: true) {
            if request.kind == .stash {
                try await self.git.stash(files, message: message, root: request.root, branch: request.branch, headOID: request.headOID)
                self.notice = "改动已保存到 Git Stash"
            } else {
                try await self.git.rollback(files, root: request.root, branch: request.branch, headOID: request.headOID)
                self.notice = "所选文件已回滚"
            }
            try await self.reload()
        }
    }

    func requestStashAction(_ entry: StashEntry, action: StashAction) {
        guard !busy, let state else { return }
        let detail: String
        switch action {
        case .apply: detail = "将改动及索引状态恢复到当前分支“\(state.branch)”，并保留记录。现有改动不会被主动清除；无法安全合并时 Git 会停止恢复。"
        case .pop: detail = "将改动及索引状态恢复到当前分支“\(state.branch)”，成功后移除记录；无法安全合并或出现冲突时保留记录。"
        case .drop: detail = "将删除此暂存记录，不修改工作区。删除后无法通过本工具恢复。"
        }
        confirmation = OperationConfirmation(title: "确认\(action.title) Stash？", message: "\(entry.reference) · \(entry.message)\n\n\(detail)", destructive: action == .drop) { [weak self] in
            guard let self, self.state?.root == state.root else { return }
            self.perform("正在\(action.title) Stash…", recover: true) {
                try await self.git.modifyStash(entry, action: action, expected: state)
                try await self.reload()
                self.notice = "Stash 已\(action.title)"
            }
        }
    }

    func clone(address: String, destination: URL) {
        perform("正在克隆仓库…") {
            let root = try await self.git.clone(address: address, destination: destination)
            let snapshot = try await self.git.snapshot(root)
            self.state = snapshot
            self.message = ""
            self.selectedPaths = []
            self.focusedFile = snapshot.files.first?.path
            self.recent.removeAll { $0 == root.path }
            self.recent.insert(root.path, at: 0)
            self.recent = Array(self.recent.prefix(8))
            UserDefaults.standard.set(self.recent, forKey: "recentRepositories")
            self.loadDiff()
            self.notice = "仓库已克隆"
        }
    }

    private func perform(_ label: String, recover: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        activity = label
        notice = nil
        Task {
            do { try await operation() }
            catch {
                self.error = error.localizedDescription
                if recover { try? await self.reload() }
            }
            busy = false
            activity = ""
        }
    }

    func revealRepository() { if let root = state?.root { NSWorkspace.shared.open(root) } }
    func openTerminal() {
        guard let root = state?.root else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([root], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: config)
    }
}
