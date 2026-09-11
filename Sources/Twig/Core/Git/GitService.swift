import Foundation
import Darwin

struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    func environmentStatus() -> GitEnvironmentStatus {
        let version = try? run(["--version"], allowFailure: true)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), version?.code == 0 else {
            return GitEnvironmentStatus(gitAvailable: false, authorNameConfigured: false, authorEmailConfigured: false)
        }
        let nameResult = try? run(["config", "--global", "--get", "user.name"], allowFailure: true)
        let emailResult = try? run(["config", "--global", "--get", "user.email"], allowFailure: true)
        let name = nameResult?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = emailResult?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GitEnvironmentStatus(gitAvailable: true, authorNameConfigured: !name.isEmpty, authorEmailConfigured: !email.isEmpty)
    }

    func watchMetadataRoots(_ root: URL) throws -> [URL] {
        try ["--git-dir", "--git-common-dir"].map { argument in
            let path = try run(["rev-parse", "--path-format=absolute", argument], at: root)
                .text.trimmingCharacters(in: .newlines)
            return URL(fileURLWithPath: path)
        }
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
        let refs = try run(["for-each-ref", "--format=%(refname)%00%(symref)%00%(upstream)%00%(objectname)", "refs/heads", "refs/remotes"], at: root).text
        var localBranches: [GitBranch] = [], remoteBranches: [GitBranch] = []
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[1].isEmpty else { continue }
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
                localBranches.append(GitBranch(ref: ref, oid: fields[3], name: String(ref.dropFirst(11)), remote: nil, upstream: fields[2], ahead: ahead, behind: behind))
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst(13))
                let remoteName = remotes.sorted { $0.count > $1.count }.first { name.hasPrefix($0 + "/") }
                remoteBranches.append(GitBranch(ref: ref, oid: fields[3], name: name, remote: remoteName, upstream: "", ahead: 0, behind: 0))
            }
        }
        let tagRefs = try run(["for-each-ref", "--sort=-version:refname", "--format=%(refname)%00%(objectname)", "refs/tags"], at: root).text
        let remoteTags = tagRefs.split(separator: "\n").compactMap { line -> GitTag? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[0].hasPrefix("refs/tags/") else { return nil }
            return GitTag(ref: fields[0], oid: fields[1], name: String(fields[0].dropFirst("refs/tags/".count)))
        }
        var operation: String?
        for (marker, label) in [("MERGE_HEAD", "合并"), ("rebase-merge", "变基"), ("rebase-apply", "变基"), ("CHERRY_PICK_HEAD", "挑选提交"), ("REVERT_HEAD", "撤销提交")] {
            let path = try run(["rev-parse", "--git-path", marker], at: root).text.trimmingCharacters(in: .newlines)
            let location = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: location.path) { operation = label; break }
        }
        return RepositorySnapshot(root: root, branch: branch, localBranches: localBranches, remoteBranches: remoteBranches, remoteTags: remoteTags, files: files, ahead: ahead, behind: behind, upstream: upstream, remote: remote, headOID: headOID, hasHEAD: head, detached: symbolic.code != 0, operation: operation)
    }

    func applyGraphCommitAction(_ action: GraphCommitAction, commit: GraphCommit, expected: RepositorySnapshot, stashChanges: Bool = false) throws {
        let current = try snapshot(expected.root)
        guard current.branch == expected.branch, current.headOID == expected.headOID,
              current.hasHEAD, !current.detached, current.operation == nil,
              !current.files.contains(where: \.isConflict), current.files == expected.files else {
            throw GitFailure(message: "仓库状态已改变，请刷新后重新确认操作。")
        }
        // Full OIDs only; no user-provided revisions or shell interpolation.
        guard [40, 64].contains(commit.oid.count), commit.oid.allSatisfy({ $0.isHexDigit }) else {
            throw GitFailure(message: "无效的提交 ID。")
        }
        let oid = try run(["rev-parse", "--verify", commit.oid + "^{commit}"], at: expected.root).text.trimmingCharacters(in: .newlines)
        let parentText = try run(["show", "-s", "--format=%P", oid], at: expected.root).text
        let parents = parentText.split(whereSeparator: \.isWhitespace).map(String.init)
        var args: [String]
        switch action {
        case let .reset(mode): args = ["reset", "--" + mode.rawValue, oid]
        case .undo:
            guard oid == current.headOID, let parent = parents.first else {
                throw GitFailure(message: "Undo Commit 仅支持当前 HEAD，且提交必须有父提交。")
            }
            args = ["reset", "--soft", parent]
        case .cherryPick, .revert:
            if parents.count > 1 {
                guard let mainline = action.mainline, (1...parents.count).contains(mainline) else {
                    throw GitFailure(message: "合并提交必须选择有效的主线父提交。")
                }
            } else if action.mainline != nil {
                throw GitFailure(message: "此提交不是合并提交，请重新选择操作。")
            }
            if case .cherryPick = action { args = ["cherry-pick", "--no-edit"] }
            else { args = ["revert", "--no-edit"] }
            if let parent = action.mainline { args += ["--mainline", String(parent)] }
            args.append(oid)
        }
        if stashChanges && action.needsCleanTree && !current.files.isEmpty {
            try run(["stash", "push", "--include-untracked", "--message", "Twig: before " + action.title + " " + commit.shortOID], at: expected.root)
        }
        try run(args, at: expected.root)
    }

    func finishGraphSequence(abort: Bool, expected: RepositorySnapshot, skip: Bool = false) throws {
        let current = try snapshot(expected.root)
        guard current.branch == expected.branch, current.headOID == expected.headOID,
              current.operation == expected.operation, let operation = current.operation,
              ["合并", "变基", "挑选提交", "撤销提交"].contains(operation) else {
            throw GitFailure(message: "进行中的操作已改变，请刷新后重试。")
        }
        if !abort && !skip && current.files.contains(where: \.isConflict) {
            throw GitFailure(message: "请先解决并暂存所有冲突。")
        }
        let commands = ["合并": "merge", "变基": "rebase", "挑选提交": "cherry-pick", "撤销提交": "revert"]
        guard let command = commands[operation], !skip || ["rebase", "cherry-pick"].contains(command) else {
            throw GitFailure(message: "当前操作不支持跳过提交。")
        }
        try run(["-c", "core.editor=true", "-c", "sequence.editor=true", command, skip ? "--skip" : (abort ? "--abort" : "--continue")], at: expected.root)
    }

    func conflictDocument(_ request: ConflictRequest) throws -> ConflictDocument {
        let root = request.expected.root
        let fileURL = root.appendingPathComponent(request.file.path)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let parent = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == resolvedRoot || parent.hasPrefix(resolvedRoot + "/") else {
            throw GitFailure(message: "文件父目录指向仓库外，无法安全解决冲突。")
        }
        let entries = try run(["ls-files", "--unmerged", "-z", "--", request.file.path], at: root).output
        var stages: [ConflictStage] = []
        for entry in entries.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            let oid = String(fields[1])
            let size = try run(["cat-file", "-s", oid], at: root).text.trimmingCharacters(in: .newlines)
            let data = (Int(size) ?? Int.max) <= 2_000_000 && fields[0] != "160000" ? try run(["cat-file", "-p", oid], at: root).output : nil
            stages.append(ConflictStage(number: stage, mode: String(fields[0]), oid: oid, data: data))
        }
        guard !stages.isEmpty else { throw GitFailure(message: "此文件已不再有未解决冲突，请关闭后刷新。") }
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
        let data: Data?
        if link != nil || values?.isDirectory == true { data = nil }
        else if FileManager.default.fileExists(atPath: fileURL.path) { data = try Data(contentsOf: fileURL, options: .mappedIfSafe) }
        else { data = nil }
        func revisionLabel(_ ref: String, fallback: String) -> String? {
            guard let revision = try? run(["rev-parse", "--verify", ref + "^{commit}"], at: root, allowFailure: true),
                  revision.code == 0 else { return nil }
            let oid = revision.text.trimmingCharacters(in: .newlines)
            let names = (try? run(["for-each-ref", "--points-at", oid, "--format=%(refname:short)", "refs/heads", "refs/remotes"], at: root).text)?
                .split(separator: "\n").prefix(2).joined(separator: ", ") ?? ""
            return "\(names.isEmpty ? fallback : names) · \(oid.prefix(8))"
        }
        var document = ConflictDocument(request: request, stages: stages, worktree: data, symbolicLink: link)
        document.oursLabel = revisionLabel("HEAD", fallback: request.expected.branch) ?? request.expected.branch
        let incomingRef: String
        switch request.expected.operation {
        case "变基": incomingRef = "REBASE_HEAD"
        case "挑选提交": incomingRef = "CHERRY_PICK_HEAD"
        case "撤销提交": incomingRef = "REVERT_HEAD"
        default: incomingRef = "MERGE_HEAD"
        }
        document.theirsLabel = revisionLabel(incomingRef, fallback: "传入提交") ?? "传入版本（来源引用不可用）"
        if request.expected.operation == "撤销提交" {
            document.theirsLabel = "撤销 \(document.theirsLabel) 的反向改动"
        }
        return document
    }

    func resolveConflict(_ document: ConflictDocument, resolution: ConflictResolution) throws {
        let request = document.request
        let root = request.expected.root
        let current = try snapshot(root)
        guard current.headOID == request.expected.headOID, current.branch == request.expected.branch,
              current.operation == request.expected.operation else { throw GitFailure(message: "仓库状态已改变，请重新打开冲突文件。") }
        let latest = try conflictDocument(request)
        guard latest.stages == document.stages else { throw GitFailure(message: "冲突版本已改变，请重新打开文件。") }
        guard latest.worktree == document.worktree, latest.symbolicLink == document.symbolicLink else {
            throw GitFailure(message: "工作区文件已被外部修改。请关闭后重新打开，避免覆盖新的改动。")
        }
        let path = request.file.path
        switch resolution {
        case let .edited(text):
            guard latest.canEdit, !MergeChunk.containsMarkers(text) else { throw GitFailure(message: "请先处理所有冲突标记；此文件必须是可编辑文本。") }
            let url = root.appendingPathComponent(path)
            try Data(text.utf8).write(to: url, options: .atomic)
            let mode = latest.ours?.mode ?? latest.theirs?.mode
            try FileManager.default.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: url.path)
            try run(["add", "--", path], at: root)
        case .ours, .theirs:
            guard latest.canSelectSide else { throw GitFailure(message: "此文件类型不支持在此面板中选择完整版本。") }
            let ours: Bool
            if case .ours = resolution { ours = true } else { ours = false }
            if (ours ? latest.ours : latest.theirs) == nil {
                try run(["rm", "--force", "--", path], at: root)
            } else {
                try run(["checkout", ours ? "--ours" : "--theirs", "--", path], at: root)
                try run(["add", "--", path], at: root)
            }

        }
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
            if var preview = SourcePreview.patch(patch) {
                preview.rollback = try rollbackContext(file, state: state, preview: preview)
                return preview
            }
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

    private func rollbackContext(_ file: ChangedFile, state: RepositorySnapshot, preview: SourcePreview) throws -> SourceRollbackContext? {
        guard state.operation == nil, !file.isConflict, !file.isUntracked, file.previousPath == nil,
              let head = state.headOID else { return nil }
        let url = state.root.appendingPathComponent(file.path)
        let root = state.root.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root || parent.hasPrefix(root + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: url), !data.contains(0), data.count <= 2_000_000 else { return nil }
        let displayed = preview.lines.filter { $0.kind != .removed }.map(\.content).joined()
        guard Data(displayed.utf8) == data else { return nil } // Includes truncation and concurrent-edit checks.
        let original = preview.lines.filter { $0.kind != .added }.map(\.content).joined()
        let originalBlob = try run(["cat-file", "-p", head + ":" + file.path], at: state.root, allowFailure: true)
        guard originalBlob.code == 0, originalBlob.output == Data(original.utf8) else { return nil }
        let entry = try run(["ls-files", "--stage", "-z", "--", file.path], at: state.root).output
        guard let parsed = rollbackIndexEntry(entry), parsed.mode.hasPrefix("100") else { return nil }
        return SourceRollbackContext(expected: state, file: file, worktree: data, indexEntry: entry, original: original)
    }

    private func rollbackIndexEntry(_ data: Data) -> (mode: String, oid: String)? {
        let entries = data.split(separator: 0)
        guard entries.count == 1, let tab = entries[0].firstIndex(of: 9) else { return nil }
        let fields = String(decoding: entries[0][..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3, fields[2] == "0" else { return nil }
        return (String(fields[0]), String(fields[1]))
    }

    func rollbackChange(_ change: SourceChange, context: SourceRollbackContext) throws {
        let root = context.expected.root, file = context.file
        let current = try snapshot(root)
        guard current.headOID == context.expected.headOID, current.branch == context.expected.branch,
              current.operation == nil, current.files.first(where: { $0.path == file.path }) == file else {
            throw GitFailure(message: "仓库或文件状态已改变，请刷新后重新选择需要回滚的改动。")
        }
        let fresh = try sourcePreview(file, in: current)
        guard fresh.rollback == context, fresh.changes.contains(change),
              let entry = rollbackIndexEntry(context.indexEntry),
              let worktree = String(data: context.worktree, encoding: .utf8) else {
            throw GitFailure(message: "文件或暂存区已改变，请重新查看差异后再回滚。")
        }
        let indexSize = try run(["cat-file", "-s", entry.oid], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(indexSize), size <= 2_000_000 else { throw GitFailure(message: "暂存版本过大，无法局部回滚。") }
        let indexData = try run(["cat-file", "-p", entry.oid], at: root).output
        guard !indexData.contains(0), let indexText = String(data: indexData, encoding: .utf8) else {
            throw GitFailure(message: "暂存版本不是 UTF-8 文本，无法局部回滚。")
        }
        let mapping = ConflictLineMap(source: indexText, result: context.original)
        for block in mapping.blocks {
            let intersects: Bool
            if change.oldLines.isEmpty {
                intersects = block.result.isEmpty ? block.result.lowerBound == change.oldLines.lowerBound :
                    block.result.contains(change.oldLines.lowerBound)
            } else {
                intersects = block.result.isEmpty ? change.oldLines.contains(block.result.lowerBound) :
                    block.result.overlaps(change.oldLines)
            }
            if intersects && (block.result.lowerBound < change.oldLines.lowerBound || block.result.upperBound > change.oldLines.upperBound) {
                throw GitFailure(message: "此处暂存改动与其他片段重叠，无法单独回滚。请先调整暂存内容后重试。")
            }
        }
        let indexRange = mapping.sourceRange(forLines: change.oldLines)
        let newIndex = Data((indexText as NSString).replacingCharacters(in: indexRange, with: change.original).utf8)
        let newWorktree = Data((worktree as NSString).replacingCharacters(in: change.worktreeRange, with: change.original).utf8)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try newIndex.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let oid = try run(["hash-object", "-w", "--", temporary.path], at: root).text.trimmingCharacters(in: .newlines)
        let url = root.appendingPathComponent(file.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: url) == context.worktree,
              try run(["ls-files", "--stage", "-z", "--", file.path], at: root).output == context.indexEntry else {
            throw GitFailure(message: "文件或暂存区已被外部修改，已取消回滚。")
        }
        try newWorktree.write(to: url, options: .atomic)
        do {
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            if newIndex != indexData {
                try run(["update-index", "--cacheinfo", entry.mode, oid, file.path], at: root)
            }
        } catch {
            if (try? Data(contentsOf: url)) == newWorktree {
                try? context.worktree.write(to: url, options: .atomic)
                if let permissions = attributes[.posixPermissions] {
                    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                }
            }
            throw error
        }
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

    func graphLog(root: URL, scope: GraphScope, sort: GraphSort, limit: Int, offset: Int) throws -> GraphPage {
        if scope == .currentBranch,
           try run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowFailure: true).code != 0 {
            return GraphPage(commits: [], hasMore: false, isShallow: false)
        }
        let count = limit + 1
        var arguments = ["log", sort.argument, "--decorate=short", "--no-color", "--max-count=\(count)", "--skip=\(offset)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s%x00%B%x1e"]
        if scope == .allBranches {
            // `--all` also expands refs/stash, which would add stash-only commits
            // and their connections to the branch graph.
            arguments += ["--exclude=refs/stash", "--all"]
        } else {
            arguments.append("HEAD")
        }
        let result = try run(arguments, at: root, allowFailure: true)
        if result.code != 0 {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitFailure(message: detail.isEmpty ? "无法读取提交历史。" : detail)
        }
        let records = result.output.split(separator: 0x1e, omittingEmptySubsequences: true)
        let commits = records.compactMap { record -> GraphCommit? in
            let fields = record.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 8 else { return nil }
            // `git log` inserts a newline between formatted records. It must
            // never become part of the OID used to connect children to parents.
            let oid = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oid.isEmpty else { return nil }
            return GraphCommit(
                oid: oid, parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2], email: fields[3], date: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
                subject: fields[6], body: fields[7].trimmingCharacters(in: .newlines), references: parseGraphReferences(fields[5])
            )
        }
        let shallow = try run(["rev-parse", "--is-shallow-repository"], at: root, allowFailure: true)
            .text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let email = try run(["config", "--get", "user.email"], at: root, allowFailure: true)
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        return GraphPage(commits: Array(commits.prefix(limit)), hasMore: commits.count > limit,
                         isShallow: shallow, currentUserEmail: email.isEmpty ? nil : email)
    }

    private func parseGraphReferences(_ decorations: String) -> [GraphReference] {
        decorations.split(separator: ",").compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value == "refs/stash" || value.hasPrefix("stash@{") { return nil }
            if value.hasPrefix("HEAD -> ") { return GraphReference(name: String(value.dropFirst(8)), kind: .head) }
            if value.hasPrefix("tag: ") { return GraphReference(name: String(value.dropFirst(5)), kind: .tag) }
            if value.contains("/") { return GraphReference(name: value, kind: .remote) }
            return value.isEmpty ? nil : GraphReference(name: value, kind: .local)
        }
    }

    func graphCommitFiles(_ oid: String, root: URL) throws -> [GraphChangedFile] {
        let parents = try run(["show", "-s", "--format=%P", oid], at: root).text.split(whereSeparator: \.isWhitespace)
        let revisions = parents.first.map { [String($0), oid] } ?? [oid]
        let data = try run(["diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames"] + revisions, at: root).output
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [GraphChangedFile] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index]
            let isRename = status.hasPrefix("R") || status.hasPrefix("C")
            let firstPath = fields[index + 1]
            index += 2
            let previousPath = isRename ? firstPath : nil
            let path: String
            if isRename, index < fields.count { path = fields[index]; index += 1 } else { path = firstPath }
            files.append(GraphChangedFile(status: status, path: path, previousPath: previousPath))
        }
        return files
    }

    func graphFilePreview(_ file: GraphChangedFile, commit: GraphCommit, root: URL) throws -> SourcePreview {
        let target = commit.oid + ":" + file.path
        let base = commit.parents.first
        let original = base.map { $0 + ":" + (file.previousPath ?? file.path) }
        for object in [original, target].compactMap({ $0 }) {
            let size = try run(["cat-file", "-s", object], at: root, allowFailure: true)
            if let bytes = Int(size.text.trimmingCharacters(in: .newlines)), bytes > 2_000_000 {
                return .message("文件超过 2 MB，请在外部工具中查看。")
            }
        }
        let options = ["--patch", "--no-ext-diff", "--no-textconv", "--no-color", "--word-diff=none", "--text", "--unified=2147483647", "--find-renames"]
        var args: [String]
        if let base { args = ["diff"] + options + [base, commit.oid, "--"] }
        else { args = ["show", "--format=", "--root"] + options + [commit.oid, "--"] }
        args += file.change.commitPaths
        let data = try run(["-c", "diff.suppressBlankEmpty=false"] + args, at: root).output
        guard !data.contains(0), let patch = String(data: data, encoding: .utf8) else {
            return .message("二进制或非 UTF-8 文件，无法显示文本差异。")
        }
        if let preview = SourcePreview.patch(patch) { return preview }
        let type = try run(["cat-file", "-t", target], at: root, allowFailure: true)
        guard type.code == 0 else { return .message("文件已删除，没有文本差异。") }
        guard type.text.trimmingCharacters(in: .newlines) == "blob" else { return .message("子模块或目录，没有文本预览。") }
        let content = try run(["cat-file", "-p", target], at: root).output
        guard !content.contains(0), let text = String(data: content, encoding: .utf8) else { return .message("二进制或非 UTF-8 文件。") }
        return .source(text, added: file.status.hasPrefix("A"), notice: text.isEmpty ? "空文件" : "没有文本改动，显示提交中的文件。")
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
    func pull(root: URL, strategy: PullStrategy) throws {
        let arguments: [String]
        switch strategy {
        case .fastForwardOnly:
            arguments = ["pull", "--ff-only", "--no-rebase"]
        case .rebase:
            arguments = ["pull", "--rebase"]
        case .merge:
            arguments = ["pull", "--no-rebase"]
        }
        try run(["-c", "merge.autostash=false", "-c", "rebase.autostash=false"] + arguments, at: root)
    }
    func push(state: RepositorySnapshot) throws {
        let current = try snapshot(state.root)
        guard current.branch == state.branch, current.upstream == state.upstream, current.remote == state.remote, current.headOID == state.headOID, !current.detached, current.operation == nil else {
            throw GitFailure(message: "仓库或分支状态已变化，请刷新后重试。")
        }
        guard let head = state.headOID else { throw GitFailure(message: "当前分支还没有提交。") }
        if state.upstream != nil {
            let remote = try run(["config", "--get", "branch.\(state.branch).remote"], at: state.root).text.trimmingCharacters(in: .newlines)
            let target = try run(["config", "--get", "branch.\(state.branch).merge"], at: state.root).text.trimmingCharacters(in: .newlines)
            guard target.hasPrefix("refs/heads/"), !remote.isEmpty else { throw GitFailure(message: "上游配置无效，请在终端检查。") }
            try run(["-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags", "--", remote, "\(head):\(target)"], at: state.root)
        } else if let remote = state.remote {
            try run(["-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags", "--", remote, "\(head):refs/heads/\(state.branch)"], at: state.root)
            try run(["config", "branch.\(state.branch).remote", remote], at: state.root)
            try run(["config", "branch.\(state.branch).merge", "refs/heads/" + state.branch], at: state.root)
        } else {
            throw GitFailure(message: "仓库没有可用的默认远程。请在终端配置 origin 后刷新。")
        }
    }
    func outgoingCommits(_ state: RepositorySnapshot) throws -> [GraphCommit] {
        guard let head = state.headOID else { return [] }
        let upstreamRef = state.localBranches.first(where: { $0.name == state.branch }).map(\.upstream).flatMap { $0.isEmpty ? nil : $0 }
        let baseline = upstreamRef ?? state.remote.map { "refs/remotes/" + $0 + "/" + state.branch }
        var revisions = [head]
        if let baseline {
            let result = try run(["rev-parse", "--verify", baseline + "^{commit}"], at: state.root, allowFailure: true)
            if result.code == 0 { revisions.append("^" + result.text.trimmingCharacters(in: .newlines)) }
        }
        let data = try run(["log", "--topo-order", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x1e"] + revisions + ["--"], at: state.root).output
        return data.split(separator: 0x1e).compactMap { record in
            let fields = record.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 6 else { return nil }
            return GraphCommit(oid: fields[0].trimmingCharacters(in: .newlines), parents: fields[1].split(separator: " ").map(String.init),
                               author: fields[2], email: fields[3], date: Date(timeIntervalSince1970: Double(fields[4]) ?? 0),
                               subject: fields[5], body: fields[5], references: [])
        }
    }

    func switchBranch(_ name: String, create: Bool, root: URL) throws {
        guard !name.hasPrefix("-"), !name.isEmpty else { throw GitFailure(message: "请输入有效的分支名称。") }
        try run(["check-ref-format", "--branch", name], at: root)
        try run(create ? ["switch", "-c", name] : ["switch", "--", name], at: root)
    }
    func switchTag(_ tag: GitTag, root: URL) throws {
        let current = try snapshot(root)
        guard current.operation == nil,
              current.remoteTags.contains(where: { $0.ref == tag.ref && $0.oid == tag.oid }) else {
            throw GitFailure(message: "远程 Tag 已变化，请刷新后重新选择。")
        }
        try run(["switch", "--detach", tag.ref], at: root)
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
    func deleteRemoteBranch(_ branch: GitBranch, root: URL) throws {
        guard branch.isRemote, let remote = branch.remote, branch.name.hasPrefix(remote + "/") else {
            throw GitFailure(message: "远程分支配置无效。")
        }
        let name = String(branch.name.dropFirst(remote.count + 1))
        let oid = branch.oid
        guard [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }) else { throw GitFailure(message: "远程分支 ID 无效，请刷新后重试。") }
        // Refuse deletion if the server advanced since the last fetch.
        try run(["-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags",
                 "--force-with-lease=refs/heads/\(name):\(oid)", "--", remote, ":refs/heads/" + name], at: root)
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
