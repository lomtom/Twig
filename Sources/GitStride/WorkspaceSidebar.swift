import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case stash = "Stash"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .commit: return "checkmark.circle"
        case .stash: return "archivebox"
        }
    }
}

struct WorkspaceSidebar: View {
    @EnvironmentObject private var model: RepositoryModel
    @Binding var selection: WorkspaceDestination?
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
                    Button { selection = destination } label: {
                        SidebarMenuLabel(
                            title: destination.rawValue,
                            icon: destination.icon,
                            showsChevron: false,
                            isSelected: selection == destination
                        )
                    }
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
}

private struct SidebarMenuLabel: View {
    let title: String
    let icon: String
    var showsChevron = true
    var isSelected = false
    var isExpanded = false
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
            BranchSwitcherRows(nodes: BranchTreeNode.build(branches), current: current, groupIDPrefix: id, expandedGroups: $expandedGroups) { branch in
                isPresented = false
                if branch.isRemote || branch.name != current { model.selectBranch(branch) }
            }
        }
    }
}

private struct BranchSwitcherRows: View {
    let nodes: [BranchTreeNode]
    let current: String
    let depth: Int
    let groupIDPrefix: String
    @Binding var expandedGroups: Set<String>
    let select: (GitBranch) -> Void

    init(nodes: [BranchTreeNode], current: String, depth: Int = 0, groupIDPrefix: String, expandedGroups: Binding<Set<String>>, select: @escaping (GitBranch) -> Void) {
        self.nodes = nodes
        self.current = current
        self.depth = depth
        self.groupIDPrefix = groupIDPrefix
        _expandedGroups = expandedGroups
        self.select = select
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
                            Image(systemName: "folder")
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
                        BranchSwitcherRows(nodes: node.children, current: current, depth: depth + 1, groupIDPrefix: groupIDPrefix, expandedGroups: $expandedGroups, select: select)
                    }
                }
            } else if let branch = node.branch {
                branchButton(branch, title: node.name)
            }
        }
    }

    private func branchButton(_ branch: GitBranch, title: String) -> some View {
        Button { select(branch) } label: {
            Label(title, systemImage: !branch.isRemote && branch.name == current ? "checkmark" : "arrow.triangle.branch")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .help(branch.name)
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
