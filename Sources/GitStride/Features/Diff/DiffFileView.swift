import SwiftUI

struct SourceFileView: View {
    let preview: SourcePreview
    let file: ChangedFile
    var moveFile: ((Int) -> Void)? = nil
    @State private var changeIndex = 0
    @State private var targetLine: Int?
    @State private var navigationID = UUID()
    private let green = Color(red: 0.25, green: 0.60, blue: 0.40)

    private var changes: [Int] {
        preview.lines.indices.filter { index in
            preview.lines[index].kind != .context && (index == 0 || preview.lines[index - 1].kind == .context)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GitStrideStyle.accent)
                    .frame(width: 28, height: 28)
                    .background(GitStrideStyle.selection, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(file.path)
                    if let previous = file.previousPath { Text("原路径：\(previous)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                StatusBadge(text: "+\(preview.additions)", color: green)
                StatusBadge(text: "−\(preview.deletions)", color: .red)
                HStack(spacing: 2) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22) }
                        .help("上一处改动").disabled(changes.isEmpty || changeIndex == 0)
                    Button { navigate(1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22) }
                        .help("下一处改动").disabled(changes.isEmpty || changeIndex == changes.count - 1)
                }.buttonStyle(.borderless)
                    .background(GitStrideStyle.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }.padding(.horizontal, 14).frame(height: 48).background(GitStrideStyle.panelHeader)
            if let notice = preview.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if preview.lines.isEmpty {
                ContentUnavailableView("没有可显示的源代码", systemImage: "doc.text").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SourceCodeScrollView(preview: preview, targetLine: targetLine, navigationID: navigationID, moveFile: moveFile)
            }
        }.onAppear { resetNavigation() }
            .onChange(of: preview.id) { _, _ in resetNavigation() }
    }

    private func resetNavigation() {
        changeIndex = 0
        targetLine = changes.first
        navigationID = UUID()
    }

    private func navigate(_ direction: Int) {
        let nextIndex = changeIndex + direction
        guard changes.indices.contains(nextIndex) else { return }
        changeIndex = nextIndex
        targetLine = changes[changeIndex]
        navigationID = UUID()
    }
}
