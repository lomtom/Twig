import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case stash = "Stash"
    case graph = "Graph"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .commit: return "checkmark.circle"
        case .stash: return "archivebox"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct WorkspaceSidebar: View {
    @EnvironmentObject private var model: RepositoryModel
    @Binding var selection: WorkspaceDestination?
    var showShortcutHints = false
    @State private var showRepositorySwitcher = false
    @State private var showBranchSwitcher = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("仓库")
                Button { showRepositorySwitcher.toggle() } label: {
                    SidebarMenuLabel(
                        title: model.state?.root.lastPathComponent ?? "Twig",
                        icon: "square.stack.3d.up.fill",
                        isExpanded: showRepositorySwitcher
                    )
                }
                .disabled(model.busy)
                .help(model.state?.root.path ?? "切换仓库")
                .popover(isPresented: $showRepositorySwitcher, arrowEdge: .trailing) {
                    RepositorySwitcher(isPresented: $showRepositorySwitcher)
                        .environmentObject(model)
                }

                if let state = model.state {
                    Button { showBranchSwitcher.toggle() } label: {
                        SidebarMenuLabel(
                            title: state.branch,
                            icon: "arrow.triangle.branch",
                            isExpanded: showBranchSwitcher
                        )
                    }
                    .disabled(model.busy || state.operation != nil)
                    .help(state.branch)
                    .popover(isPresented: $showBranchSwitcher, arrowEdge: .trailing) {
                        BranchSwitcher(isPresented: $showBranchSwitcher)
                            .environmentObject(model)
                    }
                }

                sectionTitle("工作区")
                    .padding(.top, 20)
                ForEach(WorkspaceDestination.allCases) { destination in
                    Button {
                        selection = destination
                        if destination == .commit { model.refreshCommitLocalState() }
                    } label: {
                        SidebarMenuLabel(
                            title: destination.rawValue,
                            icon: destination.icon,
                            showsChevron: false,
                            isSelected: selection == destination,
                            shortcut: showShortcutHints ? shortcut(for: destination) : nil
                        )
                    }
                    .keyboardShortcut(key(for: destination), modifiers: .command)
                    .accessibilityAddTraits(selection == destination ? .isSelected : [])
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .navigationTitle("Twig")
        .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        .accessibilityLabel("工作区导航")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private func key(for destination: WorkspaceDestination) -> KeyEquivalent {
        switch destination {
        case .commit: return "1"
        case .stash: return "2"
        case .graph: return "3"
        }
    }

    private func shortcut(for destination: WorkspaceDestination) -> String {
        switch destination {
        case .commit: return "⌘1"
        case .stash: return "⌘2"
        case .graph: return "⌘3"
        }
    }
}

private struct SidebarMenuLabel: View {
    let title: String
    let icon: String
    var showsChevron = true
    var isSelected = false
    var isExpanded = false
    var shortcut: String?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isHighlighted: Bool { (isHovering || isExpanded) && isEnabled }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let shortcut { KeyboardShortcutHint(keys: shortcut) }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.primary : Color.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor : (isHighlighted ? GitStrideStyle.panel : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHighlighted ? GitStrideStyle.hairline.opacity(0.5) : .clear)
        }
        .shadow(color: .black.opacity(isHighlighted ? 0.09 : 0), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHighlighted)
    }
}

private struct RepositorySwitcher: View {
    @EnvironmentObject private var model: RepositoryModel
    @Binding var isPresented: Bool

    private var recentPaths: [String] {
        model.recent.filter { $0 != model.state?.root.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isPresented = false
                model.chooseRepository()
            } label: {
                Label("打开仓库…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Button {
                isPresented = false
                model.showClone = true
            } label: {
                Label("克隆仓库…", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Button {
                isPresented = false
                model.closeRepository()
            } label: {
                Label("关闭项目", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let root = model.state?.root {
                        sectionTitle("当前项目 ")
                        projectButton(root.path)
                    }
                    if !recentPaths.isEmpty {
                        if model.state != nil { Divider().padding(.vertical, 4) }
                        sectionTitle("最近项目")
                        ForEach(recentPaths, id: \.self) { path in
                            projectButton(path)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(SwitcherButtonStyle())
        .padding(8)
        .frame(width: 380)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    private func projectButton(_ path: String) -> some View {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return Button {
            isPresented = false
            if path != model.state?.root.path {
                model.open(URL(fileURLWithPath: path))
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(GitStrideStyle.accent, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .help(path)
    }
}

private struct BranchSwitcher: View {
    @EnvironmentObject private var model: RepositoryModel
    @Binding var isPresented: Bool
    @State private var expandedGroups = Set<String>()
    @State private var branchEditor: BranchEditor?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                isPresented = false
                model.showBranch = true
            } label: {
                Label("创建分支…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let state = model.state {
                        branchSection("本地分支", branches: state.localBranches, current: state.branch, id: "local")
                        Divider().padding(.vertical, 4)
                        branchSection("远程分支", branches: state.remoteBranches, current: state.branch, id: "remote")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(SwitcherButtonStyle())
        .padding(8)
        .frame(width: 380)
        .onAppear { expandCurrentBranch() }
        .onChange(of: model.state?.branch) { _, _ in expandCurrentBranch() }
        .sheet(item: $branchEditor) { editor in
            switch editor {
            case let .rename(branch):
                BranchNameSheet(title: "重命名分支", placeholder: "分支名称", initialName: branch.name, confirmTitle: "重命名") { name in
                    model.renameBranch(branch, to: name)
                }
            case let .create(branch):
                BranchNameSheet(title: "新建分支", placeholder: "分支名称", confirmTitle: "创建并切换") { name in
                    model.createBranch(from: branch, named: name)
                }
            }
        }
    }

    private func expandCurrentBranch() {
        guard let state = model.state else { return }
        let upstream = state.localBranches.first { $0.name == state.branch }?.upstreamName
        for (prefix, name) in [("local", Optional(state.branch)), ("remote", upstream)] {
            guard let name else { continue }
            let parts = name.split(separator: "/")
            for count in 1..<max(1, parts.count) {
                expandedGroups.insert(prefix + ":" + parts.prefix(count).joined(separator: "/"))
            }
        }
    }

    private func branchSection(_ title: String, branches: [GitBranch], current: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            if branches.isEmpty {
                Text("暂无分支")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            let currentUpstream = model.state?.localBranches.first(where: { $0.name == current })?.upstream
            BranchSwitcherRows(nodes: BranchTreeNode.build(branches), current: current, currentUpstream: currentUpstream, groupIDPrefix: id, expandedGroups: $expandedGroups, action: handleBranchAction)
        }
    }

    private func handleBranchAction(_ branch: GitBranch, _ action: BranchMenuAction) {
        switch action {
        case .checkout:
            isPresented = false
            model.selectBranch(branch)
        case .delete:
            isPresented = false
            model.deleteBranch(branch)
        case .rename:
            branchEditor = .rename(branch)
        case .newBranch:
            branchEditor = .create(branch)
        case .rebaseOnto:
            isPresented = false
            model.rebaseCurrentBranch(onto: branch)
        case .mergeInto:
            isPresented = false
            model.mergeBranchIntoCurrent(branch)
        }
    }
}

private struct BranchSwitcherRows: View {
    let nodes: [BranchTreeNode]
    let current: String
    let currentUpstream: String?
    let depth: Int
    let groupIDPrefix: String
    @Binding var expandedGroups: Set<String>
    let action: (GitBranch, BranchMenuAction) -> Void

    init(nodes: [BranchTreeNode], current: String, currentUpstream: String?, depth: Int = 0, groupIDPrefix: String, expandedGroups: Binding<Set<String>>, action: @escaping (GitBranch, BranchMenuAction) -> Void) {
        self.nodes = nodes
        self.current = current
        self.currentUpstream = currentUpstream
        self.depth = depth
        self.groupIDPrefix = groupIDPrefix
        _expandedGroups = expandedGroups
        self.action = action
    }

    var body: some View {
        ForEach(nodes) { node in
            if !node.children.isEmpty {
                let groupID = groupIDPrefix + ":" + node.path
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if expandedGroups.contains(groupID) { expandedGroups.remove(groupID) }
                        else { expandedGroups.insert(groupID) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: expandedGroups.contains(groupID) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 12, height: 18)
                            Image(systemName: "folder").frame(width: 12)
                            Text(node.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(depth) * 14 + 8)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .help(node.path)
                    if expandedGroups.contains(groupID) {
                        if let branch = node.branch { branchButton(branch, title: node.name) }
                        BranchSwitcherRows(nodes: node.children, current: current, currentUpstream: currentUpstream, depth: depth + 1, groupIDPrefix: groupIDPrefix, expandedGroups: $expandedGroups, action: action)
                    }
                }
            } else if let branch = node.branch {
                branchButton(branch, title: node.name)
            }
        }
    }

    private func branchButton(_ branch: GitBranch, title: String) -> some View {
        Menu {
            Button("Checkout \(branch.name)") { action(branch, .checkout) }
                .disabled((!branch.isRemote && branch.name == current) || (branch.isRemote && branch.ref == currentUpstream))
            Divider()
            Button("Delete", role: .destructive) { action(branch, .delete) }
                .disabled(!branch.isRemote && branch.name == current)
            if !branch.isRemote { Button("Rename…") { action(branch, .rename) } }
            Button("New Branch…") { action(branch, .newBranch) }
            Divider()
            Button("Rebase \(current) onto \(branch.name)") { action(branch, .rebaseOnto) }
                .disabled(!branch.isRemote && branch.name == current)
            Button("Merge \(branch.name) into \(current)") { action(branch, .mergeInto) }
                .disabled(!branch.isRemote && branch.name == current)
        } label: {
            HStack(spacing: 7) {
                Color.clear.frame(width: 12, height: 18)
                Image(systemName: !branch.isRemote && branch.name == current ? "checkmark" : "arrow.triangle.branch")
                    .frame(width: 12)
                Text(title).lineLimit(1).truncationMode(.middle)
                if let difference = branch.upstreamDifference {
                    Text(difference)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let upstreamName = branch.upstreamName {
                    Text(upstreamName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .help(branch.name)
    }
}

private enum BranchMenuAction {
    case checkout, delete, rename, newBranch, rebaseOnto, mergeInto
}

private enum BranchEditor: Identifiable {
    case rename(GitBranch)
    case create(GitBranch)

    var id: String {
        switch self {
        case let .rename(branch): return "rename:" + branch.id
        case let .create(branch): return "create:" + branch.id
        }
    }
}

private struct BranchNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let confirmTitle: String
    let submit: (String) -> Void
    @State private var name: String

    init(title: String, placeholder: String, initialName: String = "", confirmTitle: String, submit: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.submit = submit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold))
            TextField(placeholder, text: $name).textFieldStyle(.roundedBorder).onSubmit(confirm)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func confirm() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        submit(value)
        dismiss()
    }
}

private struct SwitcherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    GitStrideStyle.selection.opacity(isHovering || configuration.isPressed ? 1 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onHover { isHovering = $0 }
        }
    }
}
