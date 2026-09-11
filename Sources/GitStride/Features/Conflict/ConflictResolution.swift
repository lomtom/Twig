import AppKit
import SwiftUI

struct ConflictRequest: Identifiable {
    let id = UUID()
    let expected: RepositorySnapshot
    let file: ChangedFile
}

struct ConflictStage: Equatable {
    let number: Int
    let mode: String
    let oid: String
    let data: Data?
    var text: String? {
        guard let data, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ConflictDocument {
    let request: ConflictRequest
    let stages: [ConflictStage]
    let worktree: Data?
    let symbolicLink: String?
    var oursLabel: String = "当前版本"
    var theirsLabel: String = "传入版本"
    var ours: ConflictStage? { stages.first { $0.number == 2 } }
    var theirs: ConflictStage? { stages.first { $0.number == 3 } }
    var base: ConflictStage? { stages.first { $0.number == 1 } }
    var canEdit: Bool {
        symbolicLink == nil && stages.allSatisfy { $0.mode.hasPrefix("100") && $0.text != nil } &&
        (worktree == nil || (worktree!.count <= 2_000_000 && !worktree!.contains(0) && String(data: worktree!, encoding: .utf8) != nil))
    }
    var canSelectSide: Bool { stages.allSatisfy { $0.mode.hasPrefix("100") || $0.mode == "120000" } }
    var initialText: String {
        guard canEdit else { return "" }
        return worktree.flatMap { String(data: $0, encoding: .utf8) } ?? ours?.text ?? theirs?.text ?? ""
    }
}

enum ConflictResolution {
    case edited(String), ours, theirs
}

/// Keeps line endings and non-conflicting edits intact, including diff3 markers.
struct MergeChunk: Identifiable {
    let range: Range<String.Index>
    let ours: String
    let theirs: String
    let id: Int

    static func parse(_ text: String) -> [MergeChunk] {
        var lines: [(Range<String.Index>, String)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            lines.append((cursor..<end, String(text[cursor..<end])))
            cursor = end
        }
        var result: [MergeChunk] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].1
            let markerSize = line.prefix(while: { $0 == "<" }).count
            guard markerSize >= 7 else { i += 1; continue }
            let start = i
            var base: Int?, separator: Int?, end: Int?
            i += 1
            while i < lines.count {
                if lines[i].1.hasPrefix(String(repeating: "|", count: markerSize)) { base = i }
                if lines[i].1.trimmingCharacters(in: .newlines) == String(repeating: "=", count: markerSize) { separator = i }
                if lines[i].1.hasPrefix(String(repeating: ">", count: markerSize)) { end = i; break }
                i += 1
            }
            if let separator, let end, start < separator, separator < end {
                let oursEnd = base ?? separator
                guard oursEnd > start, oursEnd <= separator else { i += 1; continue }
                result.append(MergeChunk(range: lines[start].0.lowerBound..<lines[end].0.upperBound,
                                         ours: lines[(start + 1)..<oursEnd].map(\.1).joined(),
                                         theirs: lines[(separator + 1)..<end].map(\.1).joined(), id: result.count))
            }
            i += 1
        }
        return result
    }
    static func containsMarkers(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.hasPrefix("<<<<<<<") || line.hasPrefix(">>>>>>>") || line.hasPrefix("|||||||") ||
            (line.trimmingCharacters(in: .newlines).count >= 7 && line.trimmingCharacters(in: .newlines).allSatisfy { $0 == "=" })
        }
    }
}

struct ConflictOperationBanner: View {
    @EnvironmentObject private var model: RepositoryModel
    let state: RepositorySnapshot
    private var conflicts: [ChangedFile] { state.files.filter(\.isConflict) }
    var body: some View {
        HStack(spacing: 12) {
            Label(state.operation.map { "正在\($0)" } ?? "存在合并冲突", systemImage: "exclamationmark.triangle.fill")
            Text(conflicts.isEmpty ? "所有冲突已解决，可继续操作" : "\(conflicts.count) 个文件待解决").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let first = conflicts.first {
                Button("Resolve Conflicts") { model.openConflict(first) }.disabled(model.busy)
            }
            if state.operation != nil {
                Button("Continue") { model.requestGraphSequence(abort: false) }.disabled(model.busy || !conflicts.isEmpty)
                if state.operation == "变基" || state.operation == "挑选提交" {
                    Button("Skip Commit") { model.requestSkipSequence() }.disabled(model.busy)
                }
                Button("Abort", role: .destructive) { model.requestGraphSequence(abort: true) }.disabled(model.busy)
            }
        }.font(.callout).padding(.horizontal, 16).padding(.vertical, 10).background(Color.orange.opacity(0.10))
    }
}

final class ConflictLineNumberGutter: NSView {
    weak var scrollView: NSScrollView?
    var lineCount = 1
    var selectedLine: Int?
    var selectionColor = NSColor.systemBlue
    var changedLines = Set<Int>()
    var changeColor = NSColor.systemPurple
    override var isFlipped: Bool { true }
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        guard let scrollView else { return }
        let lineHeight: CGFloat = 20
        let offset = scrollView.contentView.bounds.minY
        let first = max(0, Int((offset - 36) / lineHeight))
        let last = min(lineCount, Int((offset + bounds.height - 36) / lineHeight) + 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        guard first < last else { return }
        for index in first..<last {
            if selectedLine == index {
                selectionColor.withAlphaComponent(0.3).setFill()
                NSRect(x: 0, y: 36 + CGFloat(index) * lineHeight - offset, width: bounds.width, height: lineHeight).fill()
            }
            if changedLines.contains(index) {
                changeColor.withAlphaComponent(0.45).setFill()
                NSRect(x: 0, y: 36 + CGFloat(index) * lineHeight - offset, width: 3, height: lineHeight).fill()
            }
            ("\(index + 1)" as NSString).draw(in: NSRect(x: 4, y: 36 + CGFloat(index) * lineHeight - offset + 3, width: bounds.width - 8, height: lineHeight), withAttributes: attributes)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

struct ConflictWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConflictWindowView { ConflictWindowView() }
    func updateNSView(_ view: ConflictWindowView, context: Context) { view.configureWindow() }

    final class ConflictWindowView: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = NSSize(width: 1180, height: 560)
            guard configuredWindow !== window else { return }
            configuredWindow = window
            let available = window.screen?.visibleFrame.size ?? NSSize(width: 1420, height: 880)
            window.setContentSize(NSSize(width: 1360,
                                         height: max(560, min(820, available.height - 80))))
        }
    }
}
