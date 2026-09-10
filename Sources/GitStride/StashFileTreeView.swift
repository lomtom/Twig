import SwiftUI

struct StashFileTreeView: View {
    let files: [StashFile]
    @Binding var focusedFileID: String?
    private var focusedPath: Binding<String?> {
        Binding(get: { files.first { $0.id == focusedFileID }?.change.path },
                set: { path in focusedFileID = files.first { $0.change.path == path }?.id })
    }
    var body: some View {
        PreviewFileTreeView(files: files.map(\.change), focusedFileID: focusedPath)
    }
}
