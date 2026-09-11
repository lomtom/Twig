import AppKit

/// One independent pair of actions per block; no selection is required first.
final class ConflictBlockActionRail: NSView {
    private struct Row {
        let stack: NSStackView
        let left: NSButton
        let right: NSButton
    }
    private var rows: [Int: Row] = [:]
    var onLeft: ((Int) -> Void)?
    var onRight: ((Int) -> Void)?
    weak var scrollView: NSScrollView?
    override var isFlipped: Bool { true }

    func update(items: [ConflictDecorationOverlay.Item], offset: CGFloat) {
        guard onLeft != nil || onRight != nil else {
            for row in rows.values { row.stack.removeFromSuperview() }
            rows.removeAll()
            return
        }
        var previousBottom: CGFloat = -.greatestFiniteMagnitude
        let visible: [(ConflictDecorationOverlay.Item, CGFloat)] = items.compactMap { item in
            guard item.decoration.showsAdoptionActions else { return nil }
            let top = 36 + CGFloat(item.firstLine) * 20 - offset
            let y = max(top, previousBottom)
            previousBottom = y + 20
            return y + 20 >= 0 && y <= bounds.height ? (item, y) : nil
        }
        let ids = Set(visible.map { $0.0.decoration.id })
        for id in Array(rows.keys) where !ids.contains(id) {
            rows.removeValue(forKey: id)?.stack.removeFromSuperview()
        }
        for (item, y) in visible {
            let d = item.decoration
            let row: Row
            if let existing = rows[d.id] { row = existing }
            else {
                let left = NSButton(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "采用左侧")!, target: self, action: #selector(acceptLeft(_:)))
                let right = NSButton(image: NSImage(systemSymbolName: "arrow.left", accessibilityDescription: "采用右侧")!, target: self, action: #selector(acceptRight(_:)))
                for button in [left, right] {
                    button.tag = d.id; button.bezelStyle = .regularSquare
                    button.isBordered = false; button.controlSize = .small
                    button.widthAnchor.constraint(equalToConstant: 22).isActive = true
                    button.heightAnchor.constraint(equalToConstant: 20).isActive = true
                }
                let stack = NSStackView(views: [left, right])
                stack.orientation = .horizontal; stack.spacing = 2; stack.detachesHiddenViews = true
                row = Row(stack: stack, left: left, right: right)
                rows[d.id] = row; addSubview(stack)
            }
            let color: NSColor = d.isConflict ? .systemOrange : .systemBlue
            row.left.contentTintColor = color; row.right.contentTintColor = color
            row.left.isHidden = onLeft == nil; row.right.isHidden = onRight == nil
            row.left.isEnabled = d.canReplace && onLeft != nil
            row.right.isEnabled = d.canReplace && onRight != nil
            let disabledReason = d.canReplace ? "" : "（跨块手动编辑，请先撤销后再选择）"
            row.left.toolTip = "\(d.title)：采用左侧\(disabledReason)"
            row.right.toolTip = "\(d.title)：采用右侧\(disabledReason)"
            row.left.setAccessibilityLabel("\(d.title)，采用左侧")
            row.right.setAccessibilityLabel("\(d.title)，采用右侧")
            row.stack.frame = NSRect(x: 1, y: y, width: onLeft != nil && onRight != nil ? 46 : 22, height: 20)
            row.stack.isHidden = onLeft == nil && onRight == nil || y + 20 < 0 || y > bounds.height
        }
    }
    @objc private func acceptLeft(_ sender: NSButton) { onLeft?(sender.tag) }
    @objc private func acceptRight(_ sender: NSButton) { onRight?(sender.tag) }
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }
}
