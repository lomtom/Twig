import SwiftUI

private enum GraphStyle {
    static let rowHeight: CGFloat = 30
    static let laneSpacing: CGFloat = 16
    static let selection = Color.accentColor.opacity(0.16)
    static func color(_ token: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.24, green: 0.60, blue: 0.62),
            Color(red: 0.36, green: 0.64, blue: 0.29),
            Color(red: 0.49, green: 0.43, blue: 0.76),
            Color(red: 0.76, green: 0.51, blue: 0.28),
            Color(red: 0.32, green: 0.52, blue: 0.81),
            Color(red: 0.74, green: 0.37, blue: 0.47),
            Color(red: 0.52, green: 0.62, blue: 0.30)
        ]
        return colors[token % colors.count]
    }
}

struct GraphWorkspaceView: View {
    @EnvironmentObject private var model: RepositoryModel
    @State private var focusedFileID: String?
    @State private var preview: SourcePreview?
    @State private var previewLoading = false
    @FocusState private var graphFocused: Bool
    private var focusedFile: GraphChangedFile? { model.graphFiles.first { $0.id == focusedFileID } }
    private var previewKey: String { (model.selectedGraphCommitID ?? "") + ":" + (focusedFileID ?? "") }
    private var rows: [GraphLaneRow] { model.graphLayout.rows }
    private var searching: Bool { model.graphAuthor != nil || !model.graphQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var authors: [String] {
        Set(model.graphCommits.map(\.author) + [model.graphAuthor].compactMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var trackWidth: CGFloat { max(64, CGFloat(model.graphLayout.laneCount) * GraphStyle.laneSpacing + 24) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                ZStack {
                    graphCard
                        .opacity(focusedFileID == nil ? 1 : 0)
                        .allowsHitTesting(focusedFileID == nil)
                        .accessibilityHidden(focusedFileID != nil)
                    if focusedFileID != nil { filePreview }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).dashboardPanel()
                VStack(spacing: 10) {
                    commitDetail
                        .frame(height: min(310, max(210, geometry.size.height * 0.40)))
                        .dashboardPanel()
                    changedFiles
                        .frame(maxHeight: .infinity)
                        .dashboardPanel()
                }.frame(width: min(380, max(300, geometry.size.width * 0.30)))
            }.padding(10)
        }
        .background(GitStrideStyle.canvas)
        .onAppear { model.activateGraph() }
        .onChange(of: model.graphScope) { _, _ in model.refreshGraph() }
        .onChange(of: model.graphSort) { _, _ in model.refreshGraph() }
        .onChange(of: model.selectedGraphCommitID) { _, _ in focusedFileID = nil }
        .task(id: previewKey) { await loadPreview() }
    }

    private var graphCard: some View {
                VStack(spacing: 0) {
                    toolbar
                    if model.graphIsShallow {
                        Label("浅克隆仓库 · 提交历史可能不完整", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.09))
                    }
                    commitList
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filePreview: some View {
        VStack(spacing: 0) {
            HStack {
                Label("提交变更 · " + (model.selectedGraphCommit?.shortOID ?? ""), systemImage: "point.3.connected.trianglepath.dotted")
                if model.selectedGraphCommit?.parents.count ?? 0 > 1 { Text("相对第一父提交").foregroundStyle(.secondary) }
                Spacer()
                Button { focusedFileID = nil; graphFocused = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("关闭预览，返回提交图 Esc").keyboardShortcut(.cancelAction)
            }.font(.caption).padding(.horizontal, 14).frame(height: 36).background(GitStrideStyle.panelHeader)
            if let file = focusedFile, let preview {
                SourceFileView(preview: preview, file: file.change, moveFile: movePreviewFile)
                    .overlay(alignment: .topTrailing) { if previewLoading { ProgressView().controlSize(.small).padding(14) } }
            } else if previewLoading {
                ProgressView("正在读取变更…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法读取变更", systemImage: "doc.text")
            }
        }
    }

    private func movePreviewFile(_ step: Int) {
        let files = ChangeTreeNode.build(model.graphFiles.map(\.change)).flatMap(\.files)
        guard let index = files.firstIndex(where: { $0.id == focusedFileID }), !files.isEmpty else { return }
        focusedFileID = files[min(max(index + step, 0), files.count - 1)].id
    }

    @MainActor private func loadPreview() async {
        guard let commit = model.selectedGraphCommit, let file = focusedFile, let root = model.state?.root else {
            preview = nil; previewLoading = false; return
        }
        previewLoading = true
        do {
            let result = try await model.git.graphFilePreview(file, commit: commit, root: root)
            guard !Task.isCancelled else { return }
            preview = result
        } catch {
            guard !Task.isCancelled else { return }
            preview = .message(error.localizedDescription)
        }
        previewLoading = false
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Search commits, branches, or SHA", text: $model.graphQuery)
                .textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 230)
            Picker("Branch Scope", selection: $model.graphScope) {
                ForEach(GraphScope.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 100).disabled(model.graphLoading)
            Picker("Author", selection: $model.graphAuthor) {
                Text("All Authors").tag(String?.none)
                ForEach(authors, id: \.self) { Text($0).tag(Optional($0)) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 110)
                .help("按提交人筛选，与搜索条件同时生效")
            Spacer(minLength: 0)
            Menu {
                ForEach(GraphSort.allCases) { sort in
                    Button { model.graphSort = sort } label: {
                        if model.graphSort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.graphLoading)
                .help("\(model.graphSort.rawValue) · 时间排序按作者时间优先，并保持父提交在子提交之后")
                .accessibilityLabel("排序：\(model.graphSort.rawValue)")
            Toggle(isOn: $model.graphShowLongEdges) { Image(systemName: "line.diagonal") }
                .toggleStyle(.button)
                .help("显示完整长连线；关闭时，跨越 30 行及以上的边以两端箭头表示")
                .accessibilityLabel("显示完整长连线")
            Text("\(model.graphCommits.count) 次提交")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }.controlSize(.small).padding(.horizontal, 12).frame(height: 42)
            .background(GitStrideStyle.panelHeader)
    }

    private var commitList: some View {
        Group {
            if model.graphLoading && rows.isEmpty {
                ProgressView("正在读取提交历史…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("没有提交历史", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    // Fit the graph column to the viewport instead of forcing
                    // a document wider than the card (which creates a scroller).
                    let graphWidth = min(trackWidth, max(48, geometry.size.width * 0.28))
                    let spacing = min(GraphStyle.laneSpacing, (graphWidth - 24) / CGFloat(max(1, model.graphLayout.laneCount - 1)))
                    let matches = model.filteredGraphCommits
                    let matchIDs = Set(matches.map(\.oid))
                    ScrollViewReader { proxy in
                        VStack(spacing: 0) {
                            if searching {
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                    Text(matches.isEmpty ? "没有匹配的提交" : "匹配 \(matches.count) 条")
                                    Text("保留完整提交关系").foregroundStyle(.tertiary)
                                    Spacer()
                                    Button("Previous") { navigateMatch(matches, step: -1, proxy: proxy) }.disabled(matches.isEmpty)
                                    Button("Next") { navigateMatch(matches, step: 1, proxy: proxy) }.disabled(matches.isEmpty)
                                    Button("Clear") { model.graphQuery = ""; model.graphAuthor = nil }
                                }.font(.caption).buttonStyle(.borderless)
                                    .padding(.horizontal, 14).frame(height: 30)
                                    .background(GitStrideStyle.panelHeader)
                            }
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0) {
                                    ForEach(rows) { row in
                                        GraphCommitRow(row: row, trackWidth: graphWidth, laneSpacing: spacing,
                                                       selected: row.id == model.selectedGraphCommitID,
                                                       currentUserEmail: model.graphCurrentUserEmail,
                                                       matchesQuery: !searching || matchIDs.contains(row.id)) {
                                            model.selectGraphCommit(row.commit)
                                            graphFocused = true
                                        }.id(row.id)
                                            .contextMenu { GraphCommitContextMenu(commit: row.commit) }
                                    }
                                    if model.graphHasMore {
                                        Button(model.graphLoading ? "正在加载…" : "加载更早的提交") { model.loadMoreGraph() }
                                            .buttonStyle(.borderless).padding(12).disabled(model.graphLoading)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .focusable().focusEffectDisabled().focused($graphFocused)
                            .onKeyPress(.upArrow) { navigateCommit(-1, proxy: proxy); return .handled }
                            .onKeyPress(.downArrow) { navigateCommit(1, proxy: proxy); return .handled }
                            .defaultScrollAnchor(.top)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .onAppear { if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) } }
                            .onChange(of: model.graphSort) { _, _ in
                                if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                            }
                            .onChange(of: rows.first?.id) { _, first in
                                if let first { proxy.scrollTo(first, anchor: .top) }
                            }

                        }
                        .onChange(of: model.graphQuery) { _, _ in
                            if searching, let first = model.filteredGraphCommits.first { proxy.scrollTo(first.id, anchor: .top) }
                        }
                        .onChange(of: model.graphAuthor) { _, _ in
                            if searching, let first = model.filteredGraphCommits.first { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private func navigateCommit(_ step: Int, proxy: ScrollViewProxy) {
        let commits = searching ? model.filteredGraphCommits : model.graphCommits
        guard !commits.isEmpty else { return }
        let index = commits.firstIndex { $0.id == model.selectedGraphCommitID } ?? (step > 0 ? -1 : commits.count)
        let next = commits[min(max(index + step, 0), commits.count - 1)]
        model.selectGraphCommit(next)
        proxy.scrollTo(next.id)
    }

    private func navigateMatch(_ matches: [GraphCommit], step: Int, proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.oid == model.selectedGraphCommitID }
        let index = current.map { ($0 + step + matches.count) % matches.count } ?? (step > 0 ? 0 : matches.count - 1)
        model.selectGraphCommit(matches[index])
        proxy.scrollTo(matches[index].id, anchor: .top)
    }

    private var commitDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提交详情").fontWeight(.medium)
                Spacer()
                if let commit = model.selectedGraphCommit {
                    Text(commit.shortOID).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            if let commit = model.selectedGraphCommit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(commit.subject).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                        DetailField(title: "作者", value: "\(commit.author) <\(commit.email)>")
                        DetailField(title: "时间", value: GraphDateLabel.string(commit.date))
                        if !commit.body.isEmpty && commit.body != commit.subject {
                            Text(commit.body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !commit.references.isEmpty {
                            FlowLayout(spacing: 5) { ForEach(commit.references) { GraphReferenceBadge(reference: $0) } }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 14).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("选择一个提交查看详情").font(.caption).foregroundStyle(.tertiary).padding(16)
                Spacer()
            }
        }
    }

    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("变更文件").fontWeight(.medium)
                Spacer()
                CountBadge(value: model.graphFiles.count)
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            if model.graphDetailsLoading {
                ProgressView("正在读取文件…").frame(maxWidth: .infinity).padding(18)
                Spacer()
            } else if model.selectedGraphCommit == nil {
                Text("选择一个提交查看文件").font(.caption).foregroundStyle(.tertiary).padding(16)
                Spacer()
            } else if model.graphFiles.isEmpty {
                Text("无变更文件").font(.caption).foregroundStyle(.tertiary).padding(16)
                Spacer()
            } else {
                PreviewFileTreeView(files: model.graphFiles.map(\.change), focusedFileID: $focusedFileID)
                    .id(model.selectedGraphCommitID)
            }
        }
    }
}

private enum GraphDateLabel {
    static func string(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDateInToday(date) { return "Today " + time }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) + " " + time
    }
}

private struct GraphCommitRow: View {
    let row: GraphLaneRow
    let trackWidth: CGFloat
    let laneSpacing: CGFloat
    let selected: Bool
    let currentUserEmail: String?
    let matchesQuery: Bool
    let select: () -> Void
    @State private var hovered = false
    private var isMerge: Bool { row.commit.parents.count > 1 }
    private var isMine: Bool {
        guard let email = currentUserEmail, !email.isEmpty else { return false }
        return row.commit.email.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(email) == .orderedSame
    }
    private var textOpacity: Double { matchesQuery ? (isMerge ? 0.60 : 1) : 0.30 }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                GraphLanes(row: row, selected: selected, laneSpacing: laneSpacing).frame(width: trackWidth, height: GraphStyle.rowHeight)
                GeometryReader { geometry in
                    HStack(spacing: 8) {
                        Text(row.commit.subject.isEmpty ? "（无提交说明）" : row.commit.subject)
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(row.commit.parents.count > 1 ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !row.commit.references.isEmpty {
                            GraphReferenceStack(references: row.commit.references)
                                .frame(width: min(180, geometry.size.width * 0.40), alignment: .trailing)
                        }
                    }.frame(height: GraphStyle.rowHeight)
                }.padding(.trailing, 12).opacity(textOpacity)
                Text(row.commit.author)
                    .fontWeight(isMine ? .semibold : .regular)
                    .foregroundStyle(isMine && !isMerge ? GitStrideStyle.accent : Color.secondary)
                    .lineLimit(1).frame(width: 88, alignment: .leading)
                    .opacity(textOpacity)
                    .help(isMine ? "本人提交 · " + row.commit.email : row.commit.email)
                Text(GraphDateLabel.string(row.commit.date))
                    .lineLimit(1).monospacedDigit().frame(width: 148, alignment: .leading)
                    .opacity(textOpacity)

            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(height: GraphStyle.rowHeight)
            .background(selected ? GraphStyle.selection : (hovered ? GitStrideStyle.subtleFill.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help(row.commit.subject)
            .accessibilityLabel("\(row.commit.subject)，\(row.commit.author)，\(row.commit.shortOID)")
    }
}

private struct GraphLanes: View {
    let row: GraphLaneRow
    let selected: Bool
    let laneSpacing: CGFloat

    var body: some View {
        Canvas { context, size in
            let x: (Double) -> CGFloat = { 12 + CGFloat($0) * laneSpacing }
            let middle = size.height / 2
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            for segment in row.segments {
                var path = Path()
                path.move(to: CGPoint(x: x(segment.from), y: segment.half == .incoming ? 0 : middle))
                path.addLine(to: CGPoint(x: x(segment.to), y: segment.half == .incoming ? middle : size.height))
                context.stroke(path, with: .color(GraphStyle.color(segment.color)), style: stroke)
            }
            for arrow in row.arrows {
                let column = x(Double(arrow.lane))
                let tip = arrow.pointsDown ? size.height - 3 : 3
                let tail = tip + (arrow.pointsDown ? -4.0 : 4.0)
                var path = Path()
                path.move(to: CGPoint(x: column, y: middle))
                path.addLine(to: CGPoint(x: column, y: tip))
                path.move(to: CGPoint(x: column - 3, y: tail))
                path.addLine(to: CGPoint(x: column, y: tip))
                path.addLine(to: CGPoint(x: column + 3, y: tail))
                context.stroke(path, with: .color(GraphStyle.color(arrow.color)), style: stroke)
            }
            let column = x(Double(row.lane))
            let color = GraphStyle.color(row.nodeColor)
            let isHead = row.commit.references.contains { $0.kind == .head }
            if selected || isHead {
                let ring = CGRect(x: column - 6, y: middle - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: ring), with: .color(GitStrideStyle.panel))
                context.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: 1.5)
            }
            let radius: CGFloat = selected || isHead ? 3 : 3.75
            context.fill(Path(ellipseIn: CGRect(x: column - radius, y: middle - radius, width: radius * 2, height: radius * 2)), with: .color(color))
        }.clipped().accessibilityHidden(true)
    }
}

private struct GraphReferenceStack: View {
    let references: [GraphReference]

    private func color(_ reference: GraphReference) -> Color {
        switch reference.kind {
        case .head, .local: return Color(red: 0.35, green: 0.69, blue: 0.39)
        case .remote: return Color(red: 0.65, green: 0.47, blue: 0.83)
        case .tag: return Color(red: 0.86, green: 0.68, blue: 0.30)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                ForEach(Array(references.prefix(3).enumerated()), id: \.element.id) { index, reference in
                    ZStack {
                        Image(systemName: "tag.fill").foregroundStyle(GitStrideStyle.panel)
                        Image(systemName: "tag").foregroundStyle(color(reference))
                    }.font(.system(size: 14, weight: .medium))
                        .offset(x: CGFloat(index) * 7)
                }
            }.frame(width: 17 + CGFloat(min(references.count, 3) - 1) * 7, height: 18)
                .fixedSize().accessibilityHidden(true)
            Text(references.map(\.name).joined(separator: " & "))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }.help(references.map(\.name).joined(separator: "\n"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(references.map(\.name).joined(separator: "，"))
    }
}

private struct GraphReferenceBadge: View {
    let reference: GraphReference
    var body: some View {
        Label(reference.name, systemImage: "tag")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .lineLimit(1).truncationMode(.head)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(reference.kind == .remote ? .secondary : GitStrideStyle.accent)
            .background((reference.kind == .remote ? Color.secondary : GitStrideStyle.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct DetailField: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 42, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }.font(.caption)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var width: CGFloat = 0, height: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if width + size.width > maxWidth, width > 0 { height += lineHeight + spacing; width = 0; lineHeight = 0 }
            width += size.width + (width > 0 ? spacing : 0); lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .greatestFiniteMagnitude ? width : maxWidth, height: height + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
    }
}
