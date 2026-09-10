import SwiftUI

struct GraphFileTreeView: View {
    let files: [GraphChangedFile]
    @Binding var focusedFileID: String?
    var body: some View {
        PreviewFileTreeView(files: files.map(\.change), focusedFileID: $focusedFileID)
    }
}
