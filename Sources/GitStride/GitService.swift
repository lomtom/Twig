import Foundation
import Darwin

struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ChangedFile: Identifiable, Hashable {
    let path: String
    let previousPath: String?
    let index: Character
    let worktree: Character
    var id: String { path }
    var isUntracked: Bool { index == "?" }
    var isConflict: Bool {
        index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
    }
    var status: String {
        if isConflict { return "冲突" }
        if isUntracked || index == "A" || worktree == "A" { return "新增" }
        if index == "D" || worktree == "D" { return "删除" }
        if index == "R" || worktree == "R" { return "重命名" }
        return "修改"
    }
    var commitPaths: [String] { previousPath.map { [$0, path] } ?? [path] }
}

struct RepositorySnapshot {
    let root: URL
    let branch: String
    let localBranches: [GitBranch]
    let remoteBranches: [GitBranch]
    let files: [ChangedFile]
    let ahead: Int
    let behind: Int
    let upstream: String?
    let remote: String?
    let headOID: String?
    let hasHEAD: Bool
    let detached: Bool
    let operation: String?
}

struct CommandResult {
    let code: Int32
    let output: Data
    let error: String
    var text: String { String(decoding: output, as: UTF8.self) }
}

actor GitService {
    // Arguments are passed directly to Git, never interpreted by a shell.
    @discardableResult
    private func run(_ args: [String], at root: URL? = nil, allowFailure: Bool = false, timeout: Double = 120) throws -> CommandResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outURL = temporary.appendingPathComponent("stdout")
        let errURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL)
        let error = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "core.quotepath=false"] + args
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        }
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                completion.wait()
            }
            throw GitFailure(message: "Git 操作超时。请检查网络、凭据或仓库钩子，然后刷新仓库确认状态。")
        }
        let result = CommandResult(code: process.terminationStatus, output: try Data(contentsOf: outURL), error: String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
        if result.code != 0 && !allowFailure {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure(message: detail.isEmpty ? result.text : detail)
        }
        return result
    }

    func open(_ url: URL) throws -> URL {
        let value = try run(["rev-parse", "--show-toplevel"], at: url).text
        // Git terminates this path with one newline; preserve spaces in folder names.
        return URL(fileURLWithPath: value.hasSuffix("\n") ? String(value.dropLast()) : value)
    }

    func snapshot(_ root: URL) throws -> RepositorySnapshot {
        let headResult = try run(["rev-parse", "--verify", "HEAD"], at: root, allowFailure: true)
        let head = headResult.code == 0
        let headOID = head ? headResult.text.trimmingCharacters(in: .newlines) : nil
        let symbolic = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root, allowFailure: true)
        let branch = symbolic.code == 0 ? symbolic.text.trimmingCharacters(in: .newlines) : "游离 HEAD"
        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root).output
        let entries = status.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var offset = 0
        while offset < entries.count {
            let entry = entries[offset]
            let characters = Array(entry)
            guard characters.count >= 4 else { offset += 1; continue }
            let x = characters[0], y = characters[1]
            let path = String(characters.dropFirst(3))
            var previous: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                offset += 1
                if offset < entries.count { previous = entries[offset] }
            }
            files.append(ChangedFile(path: path, previousPath: previous, index: x, worktree: y))
            offset += 1
        }
        let tracking = try run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: root, allowFailure: true)
        let upstream = tracking.code == 0 ? tracking.text.trimmingCharacters(in: .newlines) : nil
        var ahead = 0, behind = 0
        if upstream != nil && head {
            let counts = try run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], at: root).text.split(whereSeparator: { $0.isWhitespace })
            if counts.count == 2 { ahead = Int(counts[0]) ?? 0; behind = Int(counts[1]) ?? 0 }
        }
        let remotes = try run(["remote"], at: root).text.split(separator: "\n").map(String.init)
        let remote = remotes.contains("origin") ? "origin" : (remotes.count == 1 ? remotes.first : nil)
        let refs = try run(["for-each-ref", "--format=%(refname)%00%(symref)%00%(upstream)", "refs/heads", "refs/remotes"], at: root).text
        var localBranches: [GitBranch] = [], remoteBranches: [GitBranch] = []
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, fields[1].isEmpty else { continue }
            let ref = fields[0]
            if ref.hasPrefix("refs/heads/") {
                var ahead = 0, behind = 0
                if !fields[2].isEmpty {
                    let counts = try run(["rev-list", "--left-right", "--count", ref + "..." + fields[2]], at: root, allowFailure: true)
                        .text.split(whereSeparator: { $0.isWhitespace })
                    if counts.count == 2 {
                        ahead = Int(counts[0]) ?? 0
                        behind = Int(counts[1]) ?? 0
                    }
                }
                localBranches.append(GitBranch(ref: ref, name: String(ref.dropFirst(11)), remote: nil, upstream: fields[2], ahead: ahead, behind: behind))
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst(13))
                let remoteName = remotes.sorted { $0.count > $1.count }.first { name.hasPrefix($0 + "/") }
                remoteBranches.append(GitBranch(ref: ref, name: name, remote: remoteName, upstream: "", ahead: 0, behind: 0))
            }
        }
        var operation: String?
        for (marker, label) in [("MERGE_HEAD", "合并"), ("rebase-merge", "变基"), ("rebase-apply", "变基"), ("CHERRY_PICK_HEAD", "挑选提交"), ("REVERT_HEAD", "撤销提交")] {
            let path = try run(["rev-parse", "--git-path", marker], at: root).text.trimmingCharacters(in: .newlines)
            let location = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: location.path) { operation = label; break }
        }
        return RepositorySnapshot(root: root, branch: branch, localBranches: localBranches, remoteBranches: remoteBranches, files: files, ahead: ahead, behind: behind, upstream: upstream, remote: remote, headOID: headOID, hasHEAD: head, detached: symbolic.code != 0, operation: operation)
    }

    func sourcePreview(_ file: ChangedFile, in state: RepositorySnapshot) throws -> SourcePreview {
        let url = state.root.appendingPathComponent(file.path)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
        if values?.isSymbolicLink == true {
            return .message("符号链接 → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)))
        }
        if values?.isDirectory == true { return .message("这是子模块或目录，请在终端查看其内部改动。") }
        if (values?.fileSize ?? 0) > 2_000_000 { return .message("文件超过 2 MB，请在外部编辑器中查看。") }
        if state.hasHEAD && !file.isUntracked {
            let size = try run(["cat-file", "-s", "HEAD:" + (file.previousPath ?? file.path)], at: state.root, allowFailure: true)
            if let bytes = Int(size.text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes > 2_000_000 {
                return .message("原始文件超过 2 MB，请在外部编辑器中查看。")
            }
            let patchData = try run(["-c", "diff.suppressBlankEmpty=false", "diff", "--patch", "--no-ext-diff", "--no-textconv", "--no-color", "--word-diff=none", "--text", "--unified=2147483647", "--no-indent-heuristic", "--find-renames", "HEAD", "--"] + file.commitPaths, at: state.root).output
            guard !patchData.contains(0), let patch = String(data: patchData, encoding: .utf8) else {
                return .message("二进制文件或非 UTF-8 文本，无法显示源文件。")
            }
            if let preview = SourcePreview.patch(patch) { return preview }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .message("文件已删除，且没有可预览的文本内容。") }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            return .message("二进制文件或非 UTF-8 文本，无法显示源文件。")
        }
        let added = file.isUntracked || !state.hasHEAD || file.index == "A"
        return .source(content, added: added,
                       notice: content.isEmpty ? "空文件" : (added ? nil : "没有文本改动，显示完整源文件。"))
    }

    func recentCommitMessages(root: URL) throws -> [RecentCommitMessage] {
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowFailure: true)
        if head.code == 1 { return [] }
        guard head.code == 0 else { throw GitFailure(message: head.error) }
        let email = try run(["config", "--get", "user.email"], at: root, allowFailure: true)
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw GitFailure(message: "未读取到当前仓库的 Git 用户邮箱。请先配置 user.email 后再使用提交历史。")
        }
        let escapedEmail = email.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "^", with: "\\^")
            .replacingOccurrences(of: "$", with: "\\$")
        let data = try run([
            "log", "-15", "--no-merges", "--regexp-ignore-case", "--invert-grep",
            "--grep=^Merge branch", "--grep=^Merge pull request", "--grep=^Merge request", "--grep=^See merge request",
            "--author=\(escapedEmail)", "--format=%H%x00%B", "-z", "HEAD", "--"
        ], at: root).output
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var messages: [RecentCommitMessage] = []
        var index = 0
        while index + 1 < fields.count {
            messages.append(RecentCommitMessage(id: fields[index], message: fields[index + 1].trimmingCharacters(in: .newlines)))
            index += 2
        }
        return messages
    }

    func addToGit(_ file: ChangedFile, root: URL) throws {
        try addToGit([file], root: root)
    }

    func addToGit(_ files: [ChangedFile], root: URL) throws {
        let paths = Array(Set(files.map(\.path))).sorted()
        guard !paths.isEmpty else { return }
        let current = try snapshot(root)
        guard current.operation == nil,
              paths.allSatisfy({ path in current.files.contains(where: { $0.path == path && $0.isUntracked }) }) else {
            throw GitFailure(message: "文件状态已变化，请刷新后重试。")
        }
        try run(["add", "--"] + paths, at: root)
    }

    func commit(paths: [String], message: String, root: URL) throws {
        guard !paths.isEmpty else { throw GitFailure(message: "请至少选择一个文件。") }
        let current = try snapshot(root)
        guard current.operation == nil, !current.detached, !current.files.contains(where: \.isConflict) else {
            throw GitFailure(message: "仓库状态已变化。请先处理冲突、进行中的 Git 操作或游离 HEAD。")
        }
        try run(["add", "--"] + paths, at: root)
        // --only commits the chosen files, preserving unrelated staged changes.
        try run(["commit", "--only", "-m", message, "--"] + paths, at: root)
    }

    func fetch(root: URL) throws { try run(["fetch", "--all"], at: root) }
    func pull(root: URL) throws { try run(["-c", "merge.autostash=false", "-c", "rebase.autostash=false", "pull", "--ff-only", "--no-rebase"], at: root) }
    func push(state: RepositorySnapshot) throws {
        let current = try snapshot(state.root)
        guard current.branch == state.branch, current.upstream == state.upstream, current.remote == state.remote, !current.detached, current.operation == nil else {
            throw GitFailure(message: "仓库或分支状态已变化，请刷新后重试。")
        }
        if state.upstream != nil {
            let remote = try run(["config", "--get", "branch.\(state.branch).remote"], at: state.root).text.trimmingCharacters(in: .newlines)
            let target = try run(["config", "--get", "branch.\(state.branch).merge"], at: state.root).text.trimmingCharacters(in: .newlines)
            guard target.hasPrefix("refs/heads/"), !remote.isEmpty else { throw GitFailure(message: "上游配置无效，请在终端检查。") }
            try run(["-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags", "--", remote, "HEAD:\(target)"], at: state.root)
        } else if let remote = state.remote {
            try run(["-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags", "--set-upstream", "--", remote, "HEAD:refs/heads/\(state.branch)"], at: state.root)
        } else {
            throw GitFailure(message: "仓库没有可用的默认远程。请在终端配置 origin 后刷新。")
        }
    }
    func switchBranch(_ name: String, create: Bool, root: URL) throws {
        guard !name.hasPrefix("-"), !name.isEmpty else { throw GitFailure(message: "请输入有效的分支名称。") }
        try run(["check-ref-format", "--branch", name], at: root)
        try run(create ? ["switch", "-c", name] : ["switch", "--", name], at: root)
    }
    func createBranch(_ name: String, from startPoint: String, root: URL) throws {
        guard !name.hasPrefix("-"), !name.isEmpty else { throw GitFailure(message: "请输入有效的分支名称。") }
        try run(["check-ref-format", "--branch", name], at: root)
        try run(["switch", "-c", name, startPoint], at: root)
    }
    func renameBranch(_ branch: String, to name: String, root: URL) throws {
        guard !name.hasPrefix("-"), !name.isEmpty else { throw GitFailure(message: "请输入有效的分支名称。") }
        try run(["check-ref-format", "--branch", name], at: root)
        try run(["branch", "-m", branch, name], at: root)
    }
    func deleteBranch(_ branch: String, root: URL) throws {
        try run(["branch", "-d", "--", branch], at: root)
    }
    func rebaseCurrentBranch(onto branch: String, root: URL) throws {
        try run(["rebase", "--", branch], at: root)
    }
    func mergeIntoCurrentBranch(_ branch: String, root: URL) throws {
        try run(["merge", "--no-edit", "--", branch], at: root)
    }
    func switchRemoteBranch(_ branch: GitBranch, root: URL) throws -> String {
        let current = try snapshot(root)
        guard current.operation == nil,
              current.remoteBranches.contains(where: { $0.ref == branch.ref }),
              let remote = branch.remote else {
            throw GitFailure(message: "远程分支状态已变化，请刷新后重试。")
        }
        let tracking = current.localBranches.filter { $0.upstream == branch.ref }
        if let existing = tracking.first(where: { $0.name == current.branch }) ?? (tracking.count == 1 ? tracking.first : nil) {
            try switchBranch(existing.name, create: false, root: root)
            return existing.name
        }
        let name = String(branch.name.dropFirst(remote.count + 1))
        if let existing = current.localBranches.first(where: { $0.name == name }) {
            guard existing.upstream == branch.ref else {
                throw GitFailure(message: "本地分支“\(name)”已存在，且未跟踪所选远程分支。请从本地分支列表选择，或在终端设置跟踪关系。")
            }
            try switchBranch(name, create: false, root: root)
        } else {
            guard tracking.isEmpty else { throw GitFailure(message: "多个本地分支正在跟踪此远程分支，请从本地分支列表选择。") }
            try run(["check-ref-format", "--branch", name], at: root)
            try run(["switch", "--track", "-c", name, branch.ref], at: root)
        }
        return name
    }

    func listStashes(root: URL) throws -> [StashEntry] {
        let data = try run(["stash", "list", "--format=%gd%x00%H%x00%gs%x00%ct", "-z"], at: root).output
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [StashEntry] = []
        var index = 0
        while index + 3 < fields.count {
            entries.append(StashEntry(reference: fields[index], oid: fields[index + 1], message: fields[index + 2], date: Date(timeIntervalSince1970: Double(fields[index + 3]) ?? 0)))
            index += 4
        }
        return entries
    }

    func stashFiles(_ entry: StashEntry, root: URL) throws -> [StashFile] {
        func parse(_ data: Data, indexOnly: Bool) -> [StashFile] {
            let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            var files: [StashFile] = []
            var index = 0
            while index + 1 < fields.count {
                let status = fields[index].first ?? "M"
                let first = fields[index + 1]
                var path = first, previous: String?
                index += 2
                if status == "R" || status == "C" {
                    guard index < fields.count else { break }
                    previous = first; path = fields[index]; index += 1
                }
                files.append(StashFile(change: ChangedFile(path: path, previousPath: previous, index: status, worktree: " "), untracked: false, indexOnly: indexOnly))
            }
            return files
        }
        let data = try run(["diff", "--name-status", "-z", "--find-renames", entry.oid + "^1", entry.oid, "--"], at: root).output
        var files = parse(data, indexOnly: false)
        // Include saved index changes even if the working copy had returned to HEAD.
        let indexData = try run(["diff", "--name-status", "-z", "--find-renames", entry.oid + "^1", entry.oid + "^2", "--"], at: root).output
        let workingPaths = Set(files.map { $0.change.path })
        files.append(contentsOf: parse(indexData, indexOnly: true).filter { !workingPaths.contains($0.change.path) })
        if try run(["rev-parse", "--verify", "--quiet", entry.oid + "^3"], at: root, allowFailure: true).code == 0 {
            let paths = try run(["ls-tree", "-r", "--name-only", "-z", entry.oid + "^3"], at: root).output.split(separator: 0)
            for path in paths {
                files.append(StashFile(change: ChangedFile(path: String(decoding: path, as: UTF8.self), previousPath: nil, index: "?", worktree: "?"), untracked: true))
            }
        }
        return files.sorted { $0.change.path.localizedStandardCompare($1.change.path) == .orderedAscending }
    }

    func stashPreview(_ file: StashFile, entry: StashEntry, root: URL) throws -> SourcePreview {
        let targetRevision = entry.oid + (file.untracked ? "^3" : (file.indexOnly ? "^2" : ""))
        let target = targetRevision + ":" + file.change.path
        let original = entry.oid + "^1:" + (file.change.previousPath ?? file.change.path)
        for object in file.untracked ? [target] : [original, target] {
            let size = try run(["cat-file", "-s", object], at: root, allowFailure: true)
            if let bytes = Int(size.text.trimmingCharacters(in: .newlines)), bytes > 2_000_000 {
                return .message("文件超过 2 MB，请在终端查看。")
            }
        }
        if !file.untracked {
            let data = try run(["-c", "diff.suppressBlankEmpty=false", "diff", "--patch", "--no-ext-diff", "--no-textconv", "--no-color", "--word-diff=none", "--text", "--unified=2147483647", "--find-renames", entry.oid + "^1", targetRevision, "--"] + file.change.commitPaths, at: root).output
            guard !data.contains(0), let patch = String(data: data, encoding: .utf8) else { return .message("二进制或非 UTF-8 文件，无法显示源代码。") }
            if let preview = SourcePreview.patch(patch) { return preview }
        }
        let type = try run(["cat-file", "-t", target], at: root, allowFailure: true)
        guard type.code == 0 else { return .message("文件已删除或没有可显示的内容。") }
        guard type.text.trimmingCharacters(in: .newlines) == "blob" else { return .message("子模块或目录，请在终端查看。") }
        let data = try run(["cat-file", "-p", target], at: root).output
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .message("二进制或非 UTF-8 文件，无法显示源代码。") }
        return .source(text, added: file.untracked || file.change.index == "A", notice: text.isEmpty ? "空文件" : nil)
    }

    private func validateStash(_ entry: StashEntry, root: URL) throws {
        let resolved = try run(["rev-parse", "--verify", entry.reference], at: root, allowFailure: true)
        guard resolved.code == 0, resolved.text.trimmingCharacters(in: .newlines) == entry.oid else {
            throw GitFailure(message: "Stash 列表已变化，请刷新后重新选择，避免操作其他记录。")
        }
    }

    func modifyStash(_ entry: StashEntry, action: StashAction, expected: RepositorySnapshot) throws {
        try validateStash(entry, root: expected.root)
        if action == .drop {
            try run(["stash", "drop", entry.reference], at: expected.root)
            return
        }
        let current = try snapshot(expected.root)
        guard current.branch == expected.branch, current.headOID == expected.headOID,
              current.operation == nil, !current.files.contains(where: \.isConflict) else {
            throw GitFailure(message: "当前存在冲突、进行中的 Git 操作，或分支状态已经变化。请处理后刷新并重试。")
        }
        do {
            // Apply by immutable commit ID. Never remove a record when application fails.
            try run(["stash", "apply", "--index", entry.oid], at: expected.root)
        } catch {
            throw GitFailure(message: "恢复未完成，Stash 记录已保留。工作区可能已有部分改动或冲突，请检查后处理。\n\n\(error.localizedDescription)")
        }
        if action == .pop {
            do {
                try validateStash(entry, root: expected.root)
                try run(["stash", "drop", entry.reference], at: expected.root)
            } catch {
                throw GitFailure(message: "改动已恢复，但 Stash 记录未移除。请刷新后核对并单独删除，不要再次恢复。\n\n\(error.localizedDescription)")
            }
        }
    }

    private func validateFileAction(_ files: [ChangedFile], root: URL, branch: String, headOID: String?) throws -> RepositorySnapshot {
        let current = try snapshot(root)
        guard !files.isEmpty, current.branch == branch, current.headOID == headOID, current.operation == nil,
              !current.files.contains(where: \.isConflict),
              files.allSatisfy({ current.files.contains($0) }) else {
            throw GitFailure(message: "仓库或所选文件状态已变化，请刷新后重新确认。")
        }
        for file in files {
            let values = try? root.appendingPathComponent(file.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                throw GitFailure(message: "所选文件包含子模块或目录，请在终端处理：\(file.path)")
            }
        }
        return current
    }

    func stash(_ files: [ChangedFile], message: String, root: URL, branch: String, headOID: String?) throws {
        let current = try validateFileAction(files, root: root, branch: branch, headOID: headOID)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.hasHEAD, !message.isEmpty else { throw GitFailure(message: "暂存需要至少一次提交，并填写暂存说明。") }
        let paths = Array(Set(files.flatMap(\.commitPaths))).sorted()
        try run(["stash", "push", "--include-untracked", "--message", message, "--"] + paths, at: root)
    }

    func rollback(_ files: [ChangedFile], root: URL, branch: String, headOID: String?) throws {
        let current = try validateFileAction(files, root: root, branch: branch, headOID: headOID)
        // Newly created files go to Trash; paths already in HEAD are restored by Git.
        for file in files {
            let inHEAD = try current.hasHEAD && (run(["cat-file", "-e", "HEAD:" + file.path], at: root, allowFailure: true).code == 0)
            if !inHEAD {
                let url = root.appendingPathComponent(file.path)
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                if FileManager.default.fileExists(atPath: url.path) || isLink {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }
        let trackedPaths = Array(Set(files.filter { !$0.isUntracked }.flatMap(\.commitPaths))).sorted()
        if !trackedPaths.isEmpty {
            if current.hasHEAD {
                try run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + trackedPaths, at: root)
            } else {
                try run(["rm", "--cached", "--ignore-unmatch", "--"] + trackedPaths, at: root)
            }
        }
    }

    func clone(address: String, destination: URL) throws -> URL {
        guard !address.isEmpty, !address.hasPrefix("-") else { throw GitFailure(message: "请输入有效的仓库地址。") }
        try run(["clone", "--", address, destination.path], timeout: 300)
        return try open(destination)
    }
}
