import SwiftUI
import AppKit

struct MainWorkspaceView: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var destination: WorkspaceDestination? = .commit
    @State private var commandPressed = false
    @State private var environmentStatus: GitEnvironmentStatus?

    private var mainContent: some View {
        Group {
            if model.isRestoringLastRepository { restoringRepository }
            else if let state = model.state { workspace(state) }
            else { welcome }
        }
        .tint(GitStrideStyle.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(CommandKeyMonitor(isPressed: $commandPressed).frame(width: 0, height: 0))
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if let notice = model.notice {
                    OperationNotification(kind: .success, message: notice) { model.notice = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let error = model.error {
                    OperationNotification(kind: .failure, message: error, onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    }) { model.error = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(.easeOut(duration: 0.2), value: model.notice)
            .animation(.easeOut(duration: 0.2), value: model.error)
        }
        .toolbar {
            if let state = model.state {
                if model.busy {
                    ToolbarItem(placement: .primaryAction) {
                        ProgressView().controlSize(.small).help(model.activity)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.refresh(fetch: true) } label: {
                        HStack(spacing: 4) {
                            Label("fetch", systemImage: "arrow.clockwise")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘⇧R") }
                        }
                    }
                        .labelStyle(.titleAndIcon).disabled(model.busy).help("获取远程状态并刷新 ⇧⌘R")
                    Button(action: model.pull) {
                        HStack(spacing: 4) {
                            Label(state.behind > 0 ? "pull \(state.behind)" : "pull", systemImage: "arrow.down")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘T") }
                        }
                    }.labelStyle(.titleAndIcon).disabled(!model.canSync || state.upstream == nil).help(state.upstream == nil ? "当前分支尚未设置上游" : "仅快进拉取")
                    Button(action: model.push) {
                        HStack(spacing: 4) {
                            Label(state.ahead > 0 ? "push \(state.ahead)" : "push", systemImage: "arrow.up")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘⇧K") }
                        }
                    }.labelStyle(.titleAndIcon).disabled(!model.canSync || !state.hasHEAD || (state.upstream == nil && state.remote == nil)).help(state.upstream == nil ? "推送并设置同名上游分支" : "推送当前分支")
                    Menu {
                        Button("Refresh Local Status", action: { model.refresh() })
                        Button("Show in Finder", action: model.revealRepository)
                        Button("Open in Terminal", action: model.openTerminal)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(model.state == nil ? .hidden : .automatic, for: .windowToolbar)
    }

    private var restoringRepository: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("正在恢复上次打开的项目…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presentedContent: some View {
        mainContent
        .sheet(item: $model.graphAction) { request in GraphActionSheet(request: request).environmentObject(model) }
        .sheet(item: $model.pushReview) { request in PushReviewSheet(request: request).environmentObject(model) }
        .sheet(item: $model.conflictRequest) { request in ConflictResolutionSheet(request: request).environmentObject(model) }
        .sheet(item: $model.fileAction) { request in FileActionSheet(request: request).environmentObject(model) }
        .alert(model.confirmation?.title ?? "确认操作", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }), presenting: model.confirmation) { request in
            Button("取消", role: .cancel) { model.confirmation = nil }
            Button("确认", role: request.destructive ? .destructive : nil) { model.confirmation = nil; request.action() }
        } message: { request in Text(request.message) }
        .sheet(isPresented: $model.showClone) { CloneSheet().environmentObject(model) }
        .sheet(isPresented: $model.showBranch) { BranchSheet().environmentObject(model) }
    }

    var body: some View {
        presentedContent
        .onAppear {
            model.restoreLastRepository()
            if destination == .commit { model.refreshCommitLocalState() }
        }
        .task { environmentStatus = await model.git.environmentStatus() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshCommitLocalState()
        }
        .onChange(of: model.requestedDestination) { _, value in
            if let value { destination = value; model.requestedDestination = nil }
        }
        .onChange(of: model.graphAction?.id) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.pushReview?.id) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.conflictRequest?.id) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.confirmation?.id) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.fileAction?.id) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.showClone) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.showBranch) { _, _ in model.resumeLocalRefresh() }
        .onChange(of: model.focusedFile) { _, _ in model.loadDiff(keepingPreview: true) }
    }

    private var welcome: some View {
        HStack(alignment: .center, spacing: 64) {
            VStack(alignment: .leading, spacing: 30) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(GitStrideStyle.accent)
                    .frame(width: 72, height: 72)
                    .background(GitStrideStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Twig")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .tracking(-1.5)
                    Text("专注改动，轻松提交。")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("打开一个项目，让每一次改动清晰有序。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                HStack(spacing: 12) {
                    Button(action: model.chooseRepository) {
                        HStack(spacing: 5) {
                            Label("Open Repository", systemImage: "folder")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘O") }
                        }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { model.showClone = true } label: {
                        HStack(spacing: 5) {
                            Label("Clone Repository", systemImage: "arrow.down.to.line")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘⇧O") }
                        }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(model.busy)
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.activity).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("从本地开始，与灵感一起生长。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                environmentGuidance
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("最近打开").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("继续你的工作").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    VStack(spacing: 6) {
                        ForEach(Array(model.recent.prefix(4)), id: \.self) { path in
                            Button { model.open(URL(fileURLWithPath: path)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 18, weight: .regular))
                                        .foregroundStyle(GitStrideStyle.accent)
                                        .frame(width: 38, height: 38)
                                        .background(GitStrideStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text((path as NSString).abbreviatingWithTildeInPath)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(WelcomeRepositoryButtonStyle())
                            .disabled(model.busy)
                            .help(path)
                        }
                    }
                }
                .padding(16)
                .frame(width: 340)
                .background(GitStrideStyle.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .frame(maxWidth: model.recent.isEmpty ? 420 : 880)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [GitStrideStyle.accent.opacity(0.075), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 760
                )
            }
            .ignoresSafeArea()
        }
    }

    private func workspace(_ state: RepositorySnapshot) -> some View {
        NavigationSplitView {
            WorkspaceSidebar(selection: $destination, showShortcutHints: commandPressed)
        } detail: {
            switch destination ?? .commit {
            case .commit:
                commitWorkspace(state)
            case .stash:
                StashWorkspaceView().id(state.root.path)
            case .graph:
                GraphWorkspaceView().id(state.root.path)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func commitWorkspace(_ state: RepositorySnapshot) -> some View {
        VStack(spacing: 0) {
            if state.operation != nil || state.files.contains(where: \.isConflict) {
                ConflictOperationBanner(state: state)
            } else if state.detached {
                guidanceBanner(
                    "当前处于游离 HEAD，无法提交或同步。请创建一个分支以保留后续工作。",
                    icon: "arrow.triangle.branch",
                    actionTitle: "创建分支"
                ) { model.showBranch = true }
            } else if state.remote == nil {
                guidanceBanner(
                    "此仓库尚未配置远程地址；可以继续本地提交，但暂时无法获取、拉取或推送。",
                    icon: "network",
                    actionTitle: "在终端中配置"
                ) { model.openTerminal() }
            }
            GeometryReader { geometry in
                let listWidth = min(390, max(300, geometry.size.width * 0.30))
                HStack(spacing: 10) {
                    changesList(state)
                        .frame(width: listWidth)
                        .frame(maxHeight: .infinity)
                    diffPane(state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .dashboardPanel()
                }.padding(10)
            }
        }.background(GitStrideStyle.canvas)
    }

    private func warning(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout)
            Spacer()
            Button("在终端中打开", action: model.openTerminal).buttonStyle(.link)
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder private var environmentGuidance: some View {
        if let environmentStatus, !environmentStatus.isReadyToCommit {
            VStack(alignment: .leading, spacing: 10) {
                Label("开始前检查", systemImage: "checklist")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                if !environmentStatus.gitAvailable {
                    guidanceRow(
                        "未检测到 Git",
                        detail: "请在终端运行 xcode-select --install，完成后重新打开 Twig。",
                        command: "xcode-select --install"
                    )
                }
                if environmentStatus.gitAvailable && (!environmentStatus.authorNameConfigured || !environmentStatus.authorEmailConfigured) {
                    guidanceRow(
                        "尚未配置提交身份",
                        detail: "Git 需要 user.name 和 user.email 才能创建提交。",
                        command: "git config --global user.name \"你的名字\"\ngit config --global user.email \"you@example.com\""
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: 440, alignment: .leading)
            .background(GitStrideStyle.panel.opacity(0.70), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func guidanceRow(_ title: String, detail: String, command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("复制命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                model.notice = "已复制处理命令。"
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func guidanceBanner(_ text: String, icon: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(actionTitle, action: action).buttonStyle(.link)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }

    private func changesList(_ state: RepositorySnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button { model.refresh() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        if commandPressed { KeyboardShortcutHint(keys: "⌘R") }
                    }
                }.help("刷新本地状态 ⌘R").disabled(model.busy)
                Button { model.requestFileAction(.rollback) } label: { Image(systemName: "arrow.uturn.backward") }.help("回滚所选文件").disabled(!model.canChangeFiles)
                Button { model.requestFileAction(.stash) } label: { Image(systemName: "archivebox") }.help("暂存所选文件到 Git Stash").disabled(!model.canChangeFiles || !state.hasHEAD)
                Spacer(minLength: 0)
                Button { model.treeExpansion = (UUID(), true) } label: { TreeExpansionIcon(expanded: true) }.help("全部展开").accessibilityLabel("全部展开")
                Button { model.treeExpansion = (UUID(), false) } label: { TreeExpansionIcon(expanded: false) }.help("全部折叠").accessibilityLabel("全部折叠")
            }.buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).frame(height: 48)
                .dashboardPanel(fill: GitStrideStyle.panelHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        fileSection("改动的文件", files: state.files.filter { !$0.isUntracked }, state: state)
                        fileSection("非版本控制文件", files: state.files.filter(\.isUntracked), state: state)
                    }.padding(.vertical, 8)
                }.onChange(of: model.focusedFile) { _, path in if let path { proxy.scrollTo(path) } }
            }.dashboardPanel()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.branch).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(GitStrideStyle.subtleFill, in: Capsule())
                    Spacer()
                    CommitMessageHistoryButton()
                }.font(.caption).foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    if model.message.isEmpty { Text("这次改了什么？").foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 12).allowsHitTesting(false) }
                    TextEditor(text: $model.message).font(.body).scrollContentBackground(.hidden).padding(5)
                        .accessibilityLabel("提交说明").disabled(model.busy)
                }.frame(height: 94).background(GitStrideStyle.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GitStrideStyle.hairline))
                HStack(spacing: 8) {
                    Button(action: model.commit) {
                        HStack(spacing: 4) {
                            Label("Commit \(model.selectedPaths.count)", systemImage: "checkmark")
                            if commandPressed { KeyboardShortcutHint(keys: "⌘↩") }
                        }
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).disabled(!model.canCommit)
                        .help("提交所选 \(model.selectedPaths.count) 个文件 ⌘↵")
                    Button(action: model.commitAndPush) {
                        Label("Commit and Push", systemImage: "arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered).disabled(!model.canCommitAndPush)
                        .help("提交所选文件后推送当前分支")
                }.font(.system(size: 12)).lineLimit(1)
            }.padding(14)
                .dashboardPanel(fill: GitStrideStyle.panelHeader)
        }
    }

    private func fileSection(_ title: String, files: [ChangedFile], state: RepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                CountBadge(value: files.count)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
            if files.isEmpty {
                Text("无文件").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 18).padding(.bottom, 12)
            } else {
                ChangeTreeView(nodes: ChangeTreeNode.build(files), state: state).id(state.root.path + title)
            }
        }.padding(.bottom, 6)
    }

    private func diffPane(_ state: RepositorySnapshot) -> some View {
        VStack(spacing: 0) {
            if let file = model.focusedChange {
                sourceContent(file)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(GitStrideStyle.accent.opacity(0.7))
                    Text("一切井然有序").font(.title2).fontWeight(.medium)
                    Text(emptyDescription(state)).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func sourceContent(_ file: ChangedFile) -> some View {
        if file.isConflict {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.merge").font(.largeTitle).foregroundStyle(.orange)
                Text(file.path).font(.headline)
                Text("比较两侧内容，编辑合并结果后标记为已解决。").foregroundStyle(.secondary)
                Button("Resolve Conflicts…") { model.openConflict(file) }.buttonStyle(.borderedProminent).disabled(model.busy)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.sourcePreview {
            SourceFileView(preview: preview, file: file, moveFile: model.moveFocusedFile)
                .overlay(alignment: .topTrailing) { if model.loadingDiff { ProgressView().controlSize(.small).padding(14) } }
        } else if model.loadingDiff {
            ProgressView("正在读取源文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("无法显示源文件", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyDescription(_ state: RepositorySnapshot) -> String {
        if state.ahead > 0 { return "工作区干净，还有 \(state.ahead) 个提交等待推送。" }
        if state.behind > 0 { return "远程有 \(state.behind) 个提交等待拉取。" }
        if state.upstream == nil { return "工作区干净，当前分支尚未关联上游。" }
        return "工作区干净，与上次获取的远程状态一致。"
    }

}

struct BranchSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Create Branch", systemImage: "arrow.triangle.branch").font(.title2).fontWeight(.semibold)
            Text("从当前提交创建并切换到新分支。").foregroundStyle(.secondary)
            TextField("例如 feature/new-idea", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and Switch", action: create).buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 400)
    }
    private func create() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.switchBranch(value, create: true)
        dismiss()
    }
}

struct CloneSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var folderName = ""
    @State private var parent: URL?
    @State private var validation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Clone Repository", systemImage: "square.and.arrow.down").font(.title2).fontWeight(.semibold)
            Text("支持 HTTPS 和 SSH，使用你已配置的 Git 凭据。").font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("仓库地址").font(.caption).foregroundStyle(.secondary)
                TextField("https://github.com/owner/repository.git", text: $address).textFieldStyle(.roundedBorder)
                    .onChange(of: address) { _, value in
                        let last = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? ""
                        folderName = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
                    }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("本地文件夹名称").font(.caption).foregroundStyle(.secondary)
                TextField("repository", text: $folderName).textFieldStyle(.roundedBorder)
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("保存位置").font(.caption).foregroundStyle(.secondary)
                    Text(parent?.path ?? "请选择一个父文件夹").lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "选择位置"
                    if panel.runModal() == .OK { parent = panel.url }
                }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone Repository") { clone() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderName.isEmpty || parent == nil)
            }
        }.padding(28).frame(width: 480)
    }
    private func clone() {
        guard let parent else { return }
        guard !folderName.contains("/"), folderName != ".", folderName != "..", !folderName.isEmpty else { validation = "请输入有效的文件夹名称。"; return }
        let destination = parent.appendingPathComponent(folderName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { validation = "目标文件夹已存在，请换一个名称。"; return }
        model.clone(address: address.trimmingCharacters(in: .whitespacesAndNewlines), destination: destination)
        dismiss()
    }
}

private struct TreeExpansionIcon: View {
    let expanded: Bool

    var body: some View {
        Path { path in
            // Outward chevrons expand the tree; inward chevrons collapse it.
            path.move(to: CGPoint(x: 3, y: expanded ? 4 : 1))
            path.addLine(to: CGPoint(x: 6.5, y: expanded ? 1 : 4))
            path.addLine(to: CGPoint(x: 10, y: expanded ? 4 : 1))
            path.move(to: CGPoint(x: 3, y: expanded ? 9 : 12))
            path.addLine(to: CGPoint(x: 6.5, y: expanded ? 12 : 9))
            path.addLine(to: CGPoint(x: 10, y: expanded ? 9 : 12))
        }
        .stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

private struct WelcomeRepositoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WelcomeRepositoryButton(configuration: configuration)
    }

    private struct WelcomeRepositoryButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(isEnabled && (isHovering || configuration.isPressed) ? GitStrideStyle.panel : .clear, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(isEnabled && isHovering ? 0.045 : 0), radius: 8, y: 3)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        }
    }
}
