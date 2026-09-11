import AppKit
import SwiftUI

private let sourceRowHeight: CGFloat = 23
private let sourceTopInset: CGFloat = 10
private let gutterWidth: CGFloat = 144
private let sourceChangeOverviewWidth: CGFloat = 4

private func sourceChangeColor(_ kind: SourceLine.Kind) -> NSColor {
    switch kind {
    case .context: return .clear
    case .added: return NSColor.systemGreen
    case .removed: return NSColor.systemRed
    }
}

private func sourceChangeFill(_ kind: SourceLine.Kind, appearance: NSAppearance) -> NSColor {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
        return sourceChangeColor(kind).withAlphaComponent(0.22)
    }
    switch kind {
    case .context: return .clear
    case .added: return NSColor(calibratedRed: 0.80, green: 0.94, blue: 0.84, alpha: 1)
    case .removed: return NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.85, alpha: 1)
    }
}

private func sourceChangeEdge(_ kind: SourceLine.Kind, appearance: NSAppearance) -> NSColor {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    switch kind {
    case .context: return .clear
    case .added:
        return isDark ? .systemGreen : NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.25, alpha: 1)
    case .removed:
        return isDark ? .systemRed : NSColor(calibratedRed: 0.88, green: 0.12, blue: 0.18, alpha: 1)
    }
}

struct SourceCodeScrollView: NSViewRepresentable {
    let preview: SourcePreview
    let targetLine: Int?
    let navigationID: UUID
    var moveFile: ((Int) -> Void)? = nil
    var rollbackChange: ((SourceChange) -> Void)? = nil

    func makeNSView(context: Context) -> SourceScrollContainer { SourceScrollContainer() }
    func updateNSView(_ view: SourceScrollContainer, context: Context) {
        view.moveFile = moveFile
        view.rollbackChange = rollbackChange
        view.update(preview: preview, targetLine: targetLine, navigationID: navigationID)
    }
}

final class SourceScrollContainer: NSView {
    private let scrollView = NSScrollView()
    private let code = SourceTextView()
    private let gutter = SourceGutterView()
    private let changeOverview = SourceChangeOverviewView()
    var moveFile: ((Int) -> Void)? { didSet { code.moveFile = moveFile } }
    var rollbackChange: ((SourceChange) -> Void)?
    private var changes: [SourceChange] = []
    private var rollbackButtons: [Int: NSButton] = [:]
    private var displayedLines: [SourceLine] = []
    private var previewID: UUID?
    private var navigationID: UUID?
    private var pendingLine: Int?
    private var contentWidth: CGFloat = 0
    private var rows = 0
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        code.isEditable = false
        code.isSelectable = true
        code.isRichText = false
        code.isVerticallyResizable = false
        code.isHorizontallyResizable = false
        code.textContainerInset = NSSize(width: 0, height: sourceTopInset)
        code.textContainer?.lineFragmentPadding = 8
        code.textContainer?.widthTracksTextView = false
        code.textContainer?.heightTracksTextView = false
        code.setAccessibilityLabel("源文件代码")
        scrollView.documentView = code
        gutter.scrollView = scrollView
        changeOverview.scrollView = scrollView
        addSubview(scrollView)
        addSubview(gutter)
        addSubview(changeOverview)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(preview: SourcePreview, targetLine: Int?, navigationID: UUID) {
        changes = preview.rollback == nil ? [] : preview.changes
        if previewID != preview.id || displayedLines != preview.lines {
            let changedFile = previewID != preview.id
            displayedLines = preview.lines
            previewID = preview.id
            rows = preview.lines.count
            code.lines = preview.lines
            gutter.lines = preview.lines
            changeOverview.lines = preview.lines
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = sourceRowHeight
            paragraph.maximumLineHeight = sourceRowHeight
            paragraph.lineBreakMode = .byClipping
            let text = NSMutableAttributedString(string: "")
            contentWidth = 0
            for line in preview.lines {
                let visible = line.text.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "")
                contentWidth = max(contentWidth, (visible as NSString).size(withAttributes: [.font: font]).width + 32)
                text.append(NSAttributedString(string: visible + "\n", attributes: [
                    .font: font,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraph
                ]))
            }
            code.textStorage?.setAttributedString(text)
            if changedFile {
                scrollView.contentView.scroll(to: .zero)
                pendingLine = targetLine ?? preview.lines.firstIndex(where: { $0.kind != .context }) ?? 0
            }
            code.needsDisplay = true
            gutter.needsDisplay = true
            changeOverview.needsDisplay = true
        }
        if self.navigationID != navigationID {
            self.navigationID = navigationID
            if let targetLine { pendingLine = targetLine }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle)
        changeOverview.frame = NSRect(
            x: max(gutterWidth, scrollView.frame.maxX - scrollerWidth - sourceChangeOverviewWidth - 5),
            y: 5,
            width: sourceChangeOverviewWidth,
            height: max(0, bounds.height - 10)
        )
        let width = max(contentWidth, scrollView.contentSize.width)
        let height = max(CGFloat(rows) * sourceRowHeight + sourceTopInset * 2, scrollView.contentSize.height)
        code.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        code.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if let line = pendingLine, bounds.height > 0 {
            pendingLine = nil
            let y = max(0, min(sourceTopInset + CGFloat(line) * sourceRowHeight - scrollView.contentSize.height * 0.28, height - scrollView.contentSize.height))
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        gutter.needsDisplay = true
        changeOverview.needsDisplay = true
        updateRollbackButtons()
    }

    private func updateRollbackButtons() {
        let offset = scrollView.contentView.bounds.minY
        let visible = rollbackChange == nil ? [] : changes.filter {
            let y = sourceTopInset + CGFloat($0.id) * sourceRowHeight - offset
            return y + sourceRowHeight >= 0 && y < bounds.height
        }
        let ids = Set(visible.map(\.id))
        for id in Array(rollbackButtons.keys) where !ids.contains(id) {
            rollbackButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for change in visible {
            let button: NSButton
            if let existing = rollbackButtons[change.id] { button = existing }
            else {
                button = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "回滚此处改动")!,
                                  target: self, action: #selector(rollback(_:)))
                button.tag = change.id; button.isBordered = false; button.controlSize = .small
                button.toolTip = "回滚此处改动到 HEAD，保留其他改动"
                button.setAccessibilityLabel("回滚第 \(change.id + 1) 行附近的改动")
                rollbackButtons[change.id] = button; addSubview(button)
            }
            button.frame = NSRect(x: 118, y: sourceTopInset + CGFloat(change.id) * sourceRowHeight - offset, width: 22, height: sourceRowHeight)
        }
    }
    @objc private func rollback(_ sender: NSButton) {
        if let change = changes.first(where: { $0.id == sender.tag }) { rollbackChange?(change) }
    }
    @objc private func didScroll() { gutter.needsDisplay = true; updateRollbackButtons() }
}

private final class SourceTextView: NSTextView {
    var moveFile: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if let moveFile, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
           event.keyCode == 125 || event.keyCode == 126 {
            moveFile(event.keyCode == 125 ? 1 : -1)
        } else { super.keyDown(with: event) }
    }

    var lines: [SourceLine] = []
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let first = max(0, Int((rect.minY - sourceTopInset) / sourceRowHeight))
        let last = min(lines.count, Int((rect.maxY - sourceTopInset) / sourceRowHeight) + 1)
        guard first < last else { return }
        for index in first..<last where lines[index].kind != .context {
            sourceChangeFill(lines[index].kind, appearance: effectiveAppearance).setFill()
            NSRect(x: 0, y: sourceTopInset + CGFloat(index) * sourceRowHeight, width: bounds.width, height: sourceRowHeight).fill()
        }
    }
}

private final class SourceGutterView: NSView {
    weak var scrollView: NSScrollView?
    var lines: [SourceLine] = []
    override var isFlipped: Bool { true }
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let offset = scrollView?.contentView.bounds.minY ?? 0
        let first = max(0, Int((offset - sourceTopInset) / sourceRowHeight))
        let last = min(lines.count, Int((offset + bounds.height - sourceTopInset) / sourceRowHeight) + 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        guard first < last else { return }
        for index in first..<last {
            let line = lines[index]
            let y = sourceTopInset + CGFloat(index) * sourceRowHeight - offset
            if line.kind != .context {
                sourceChangeFill(line.kind, appearance: effectiveAppearance).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: sourceRowHeight).fill()
                sourceChangeEdge(line.kind, appearance: effectiveAppearance).setFill()
                NSRect(x: 0, y: y, width: 4, height: sourceRowHeight).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
            ((line.oldNumber.map(String.init) ?? "") as NSString).draw(in: NSRect(x: 4, y: y + 4, width: 42, height: 18), withAttributes: attributes)
            ((line.newNumber.map(String.init) ?? "") as NSString).draw(in: NSRect(x: 48, y: y + 4, width: 42, height: 18), withAttributes: attributes)
            let symbol = line.kind == .added ? "+" : (line.kind == .removed ? "−" : "")
            (symbol as NSString).draw(in: NSRect(x: 98, y: y + 4, width: 14, height: 18), withAttributes: [.font: font, .foregroundColor: sourceChangeEdge(line.kind, appearance: effectiveAppearance)])
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Shows the location of every changed line against the whole file, beside the vertical scroller.
private final class SourceChangeOverviewView: NSView {
    weak var scrollView: NSScrollView?
    var lines: [SourceLine] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty, bounds.height > 0 else { return }
        let documentHeight = max(
            CGFloat(lines.count) * sourceRowHeight + sourceTopInset * 2,
            scrollView?.documentView?.bounds.height ?? 0
        )
        guard documentHeight > 0 else { return }

        let availableHeight = bounds.height
        let minimumMarkerHeight: CGFloat = 3
        let scaledRowHeight = max(minimumMarkerHeight, sourceRowHeight / documentHeight * availableHeight)
        NSColor.systemBlue.withAlphaComponent(0.78).setFill()

        for index in lines.indices where lines[index].kind != .context {
            let documentY = sourceTopInset + CGFloat(index) * sourceRowHeight
            let y = documentY / documentHeight * availableHeight
            NSRect(x: 0, y: y, width: bounds.width, height: scaledRowHeight).fill()
        }
    }

    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView, let documentView = scrollView.documentView, bounds.height > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let targetY = min(max(0, location.y / bounds.height * documentView.bounds.height - scrollView.contentSize.height * 0.5), max(0, documentView.bounds.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
