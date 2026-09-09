import SwiftUI

struct FileActionRequest: Identifiable {
    enum Kind { case rollback, stash }
    let id = UUID()
    let kind: Kind
    let root: URL
    let branch: String
    let headOID: String?
    let files: [ChangedFile]
}

struct OperationConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var destructive = false
    let action: @MainActor () -> Void
}

struct FileActionSheet: View {
    @EnvironmentObject private var model: RepositoryModel
    @Environment(\.dismiss) private var dismiss
    let request: FileActionRequest
    @State private var selected: Set<String>
    @State private var message = ""

    init(request: FileActionRequest) {
        self.request = request
        _selected = State(initialValue: Set(request.files.map(\.path)))
    }

    private var isStash: Bool { request.kind == .stash }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isStash ? "暂存改动" : "确认回滚文件", systemImage: isStash ? "archivebox" : "arrow.uturn.backward")
                .font(.title2).fontWeight(.semibold)
            Text(isStash ? "将所选文件保存到 Git Stash，并从工作区移除这些改动。" : "已跟踪文件恢复到 HEAD，已暂存和未暂存的改动都会丢失；新增文件移入废纸篓。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.files) { file in
                        Toggle(isOn: Binding(get: { selected.contains(file.path) }, set: { on in
                            if on { selected.insert(file.path) } else { selected.remove(file.path) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path).font(.system(size: 12, design: .monospaced))
                                if let old = file.previousPath { Text("原路径：\(old)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(height: min(240, CGFloat(request.files.count) * 40 + 20))
                .background(GitStrideStyle.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GitStrideStyle.hairline))
            if isStash {
                TextField("暂存说明（必填）", text: $message).textFieldStyle(.roundedBorder)
                Text("可在左侧 Stash 菜单查看和恢复。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(selected.count) 个文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isStash ? "暂存" : "确认回滚", role: isStash ? nil : .destructive) {
                    model.executeFileAction(request, paths: selected, message: message)
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || (isStash && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(24).frame(width: 520)
    }
}
