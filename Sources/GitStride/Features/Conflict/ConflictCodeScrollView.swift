import AppKit
import SwiftUI

struct ConflictCodeScrollView: NSViewRepresentable {
    let text: String
    var editing: ConflictEditingSession? = nil
    @Binding var scrollLine: CGFloat
    var synchronized = true
    var lineMap: ConflictLineMap? = nil
    var navigation: UUID
    var selectedRange: NSRange? = nil
    var conflictRanges: [NSRange] = []
    var changedLines: Set<Int> = []
    var changeColor: NSColor = .systemPurple
    var decorations: [ConflictCodeDecoration] = []
    var selectedID: Int? = nil
    var onSelect: ((Int) -> Void)? = nil
    var acceptLeft: ((Int) -> Void)? = nil
    var acceptRight: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> ConflictCodeScrollContainer { ConflictCodeScrollContainer() }
    func updateNSView(_ view: ConflictCodeScrollContainer, context: Context) {
        view.onScroll = { scrollLine = $0 }
        view.update(self)
    }
}

private final class ConflictTextView: NSTextView {
    weak var session: ConflictEditingSession?
    override var undoManager: UndoManager? { session?.history ?? super.undoManager }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z", let session {
            if event.modifierFlags.contains(.shift) { session.redo() } else { session.undo() }
            return
        }
        super.keyDown(with: event)
    }
    @objc func undo(_ sender: Any?) { session?.undo() }
    @objc func redo(_ sender: Any?) { session?.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return session?.history.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return session?.history.canRedo == true }
        return super.validateMenuItem(menuItem)
    }
}

final class ConflictCodeScrollContainer: NSView, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    private let textView = ConflictTextView()
    private let gutter = ConflictLineNumberGutter()
    private let actions = ConflictBlockActionRail()
    private let overlay = ConflictDecorationOverlay()
    private let lineHeight: CGFloat = 20
    private var configuration: ConflictCodeScrollView?
    private var navigation: UUID?
    private var lastScrollLine: CGFloat?
    private var applying = false
    private var contentWidth: CGFloat = 0
    var onScroll: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true; scrollView.borderType = .noBorder; scrollView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        // The session records text edits and button actions in the same history.
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 36)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.delegate = self
        scrollView.documentView = textView
        gutter.scrollView = scrollView
        addSubview(gutter); addSubview(scrollView); addSubview(overlay)
        overlay.scrollView = scrollView
        actions.scrollView = scrollView
        addSubview(actions)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(_ value: ConflictCodeScrollView) {
        let previous = configuration
        configuration = value
        textView.session = value.editing
        textView.isEditable = value.editing != nil
        let textChanged = textView.string != value.text
        if textChanged {
            let selection = textView.selectedRange()
            applying = true
            textView.string = value.text
            textView.setSelectedRange(NSRange(location: min(selection.location, (value.text as NSString).length), length: 0))
            applying = false
            measure()
        }
        if textChanged || previous?.selectedRange != value.selectedRange || previous?.conflictRanges != value.conflictRanges || previous?.changedLines != value.changedLines || previous?.changeColor != value.changeColor || previous?.decorations != value.decorations || previous?.selectedID != value.selectedID {
            highlight()
        }
        overlay.onSelect = value.onSelect
        actions.onLeft = value.acceptLeft; actions.onRight = value.acceptRight
        let shouldNavigate = navigation != value.navigation
        layoutSubtreeIfNeeded()
        if shouldNavigate, let range = value.selectedRange {
            navigation = value.navigation
            // Explicit navigation is the only operation that moves the editing viewport.
            applying = true
            let line = (textView.string as NSString).substring(to: clamp(range).location).components(separatedBy: "\n").count - 1
            setLine(CGFloat(max(0, line - 2)))
            applying = false
            if value.editing != nil { publishScroll() }
        } else if previous?.synchronized == false, value.synchronized, value.editing != nil {
            publishScroll()
        } else if value.synchronized, value.editing == nil || !textChanged,
                  previous?.synchronized != true || lastScrollLine != value.scrollLine || (value.editing == nil && previous?.text != value.text) {
            setLine(value.lineMap?.sourceLine(forResult: value.scrollLine) ?? value.scrollLine)
        }
        lastScrollLine = value.scrollLine
        positionActions()
    }
    private func measure() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
        textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        textView.textStorage?.addAttributes(textView.typingAttributes, range: NSRange(location: 0, length: (textView.string as NSString).length))
        let lines = textView.string.components(separatedBy: "\n")
        gutter.lineCount = lines.count
        contentWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width + 16 }.max() ?? 0
        needsLayout = true
    }
    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: 42, height: bounds.height)
        actions.frame = NSRect(x: 42, y: 0, width: 48, height: bounds.height)
        scrollView.frame = NSRect(x: 90, y: 0, width: max(0, bounds.width - 90), height: bounds.height)
        overlay.frame = scrollView.frame
        let width = max(contentWidth, scrollView.contentSize.width)
        let height = max(CGFloat(gutter.lineCount) * lineHeight + 72, scrollView.contentSize.height)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        applying = true
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        applying = false
        gutter.needsDisplay = true; positionActions()
    }
    private func clamp(_ range: NSRange) -> NSRange {
        let length = (textView.string as NSString).length
        let start = min(range.location, length)
        return NSRange(location: start, length: min(range.length, length - start))
    }
    private func highlight() {
        guard let configuration, let manager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        let text = textView.string as NSString
        var location = 0, line = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            if configuration.changedLines.contains(line) {
                manager.addTemporaryAttribute(.backgroundColor, value: configuration.changeColor.withAlphaComponent(0.17), forCharacterRange: range)
            }
            location = NSMaxRange(range); line += 1
        }
        for range in configuration.conflictRanges {
            manager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.18), forCharacterRange: clamp(range))
        }
        if let range = configuration.selectedRange {
            manager.addTemporaryAttribute(.backgroundColor, value: (configuration.decorations.first { $0.id == configuration.selectedID }?.isConflict == true ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.25), forCharacterRange: clamp(range))
        }
        gutter.selectedLine = configuration.selectedRange.map {
            (textView.string as NSString).substring(to: clamp($0).location).components(separatedBy: "\n").count - 1
        }
        overlay.update(text: textView.string, decorations: configuration.decorations, selectedID: configuration.selectedID)
        gutter.selectionColor = configuration.decorations.first { $0.id == configuration.selectedID }?.isConflict == true ? .systemOrange : .systemBlue
        gutter.changedLines = configuration.changedLines; gutter.changeColor = configuration.changeColor
        gutter.needsDisplay = true; textView.needsDisplay = true
    }
    private func setLine(_ line: CGFloat) {
        let maximum = max(0, textView.bounds.height - scrollView.contentSize.height)
        let y = min(maximum, max(0, line * lineHeight))
        guard abs(scrollView.contentView.bounds.minY - y) > 0.5 else { return }
        applying = true
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        applying = false
    }
    private func publishScroll() {
        guard let configuration, configuration.synchronized else { return }
        let line = scrollView.contentView.bounds.minY / lineHeight
        let canonical = configuration.lineMap?.resultLine(forSource: line) ?? line
        lastScrollLine = canonical
        // Avoid publishing SwiftUI state during NSViewRepresentable updates.
        DispatchQueue.main.async { [weak self] in self?.onScroll?(canonical) }
    }
    @objc private func didScroll() {
        gutter.needsDisplay = true; positionActions()
        guard !applying else { return }
        publishScroll()
    }
    private func positionActions() {
        let offset = scrollView.contentView.bounds.minY
        overlay.offset = offset
        overlay.needsDisplay = true
        actions.update(items: overlay.items, offset: offset)
    }
    func textDidChange(_ notification: Notification) {
        guard !applying else { return }
        configuration?.editing?.edit(textView.string)
        measure()
    }
}
