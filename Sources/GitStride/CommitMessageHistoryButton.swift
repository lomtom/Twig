import SwiftUI

struct RecentCommitMessage: Identifiable {
    let id: String
    let message: String
    var subject: String { message.split(separator: "\n").first.map(String.init) ?? "（空提交说明）" }
}

struct CommitMessageHistoryButton: View {
    @EnvironmentObject private var model: RepositoryModel
    @State private var isPresented = false
    @State private var entries: [RecentCommitMessage] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var loadedContext = ""

    private var contextID: String {
        [model.state?.root.path ?? "", model.state?.branch ?? "", model.state?.headOID ?? ""].joined(separator: "\0")
    }

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "clock.arrow.circlepath")
                .frame(width: 24, height: 24)
                .background(GitStrideStyle.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }.buttonStyle(.borderless).disabled(model.busy)
            .help("选择我的最近 15 次提交信息").accessibilityLabel("我的提交历史")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if loading {
                        ProgressView("正在读取…").frame(maxWidth: .infinity).padding(24)
                    } else if let failure {
                        Text(failure).font(.callout).foregroundStyle(.secondary).padding(16)
                    } else if entries.isEmpty {
                        Text("当前分支没有你的提交记录").foregroundStyle(.secondary).padding(24)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                sectionTitle("最近提交")
                                ForEach(entries) { entry in
                                    CommitMessageHistoryRow(entry: entry) {
                                        guard !model.busy, loadedContext == contextID else { return }
                                        model.message = entry.message
                                        isPresented = false
                                    }
                                    .disabled(model.busy)
                                    .help(entry.message)
                                }
                            }.padding(8)
                        }.frame(height: min(280, CGFloat(entries.count) * 48 + 42))
                    }
                }.frame(width: 580)
                    .task(id: contextID) { await load() }
            }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    @MainActor private func load() async {
        guard let state = model.state else { return }
        let context = contextID
        loading = true
        failure = nil
        entries = []
        do {
            let result = try await model.git.recentCommitMessages(root: state.root)
            guard !Task.isCancelled, context == contextID else { return }
            entries = result
            loadedContext = context
        } catch {
            guard !Task.isCancelled, context == contextID else { return }
            failure = "读取失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

private struct CommitMessageHistoryRow: View {
    let entry: RecentCommitMessage
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 10) {
                Text(entry.subject)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .contentShape(Rectangle())
            .background(GitStrideStyle.selection.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
