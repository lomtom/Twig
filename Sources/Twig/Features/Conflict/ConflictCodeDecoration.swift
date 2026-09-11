import AppKit

struct ConflictCodeDecoration: Equatable {
    let id: Int
    let range: NSRange
    let title: String
    let isConflict: Bool
    let canReplace: Bool
    let showsAdoptionActions: Bool
}

/// Draws full-width outlines and zero-length insertion/deletion anchors. Only the
/// numbered badges receive clicks; text selection and editing pass through.
final class ConflictDecorationOverlay: NSView {
    struct Item {
        let decoration: ConflictCodeDecoration
        let firstLine: Int
        let endLine: Int
    }
    var items: [Item] = []
    var selectedID: Int?
    var offset: CGFloat = 0
    var onSelect: ((Int) -> Void)?
    weak var scrollView: NSScrollView?
    private var badges: [(NSRect, Int)] = []
    override var isFlipped: Bool { true }

    func update(text: String, decorations: [ConflictCodeDecoration], selectedID: Int?) {
        let string = text as NSString
        var starts = [0], cursor = 0
        while cursor < string.length {
            cursor = NSMaxRange(string.lineRange(for: NSRange(location: cursor, length: 0)))
            if cursor < string.length { starts.append(cursor) }
        }
        if text.hasSuffix("\n") { starts.append(string.length) }
        func line(_ location: Int) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= location { low = middle + 1 } else { high = middle }
            }
            return max(0, low - 1)
        }
        items = decorations.map { d in
            let first = line(min(d.range.location, string.length))
            let last = d.range.length == 0 ? first : line(min(NSMaxRange(d.range) - 1, string.length)) + 1
            return Item(decoration: d, firstLine: first, endLine: last)
        }
        self.selectedID = selectedID
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        badges = []
        for item in items {
            let d = item.decoration
            let top = 36 + CGFloat(item.firstLine) * 20 - offset
            let bottom = 36 + CGFloat(item.endLine) * 20 - offset
            guard bottom >= 0, top <= bounds.height else { continue }
            let color: NSColor = d.isConflict ? .systemOrange : .systemBlue
            let selected = selectedID == d.id
            color.withAlphaComponent(selected ? 0.9 : 0.45).setStroke()
            let outline: NSBezierPath
            if d.range.length == 0 {
                outline = NSBezierPath()
                outline.move(to: NSPoint(x: 4, y: top))
                outline.line(to: NSPoint(x: max(4, bounds.width - 18), y: top))
                outline.setLineDash([4, 3], count: 2, phase: 0)
            } else {
                outline = NSBezierPath(rect: NSRect(x: 4, y: top, width: max(0, bounds.width - 22), height: max(20, bottom - top)))
            }
            outline.lineWidth = selected ? 2 : 1
            outline.stroke()
            let label = d.title + (d.range.length == 0 ? " · 此处无内容" : "")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: selected ? .semibold : .regular),
                .foregroundColor: color
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let width = min(size.width + 12, max(0, bounds.width - 24))
            let badge = NSRect(x: max(4, bounds.width - width - 18), y: max(0, top - 16), width: width, height: 16)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            (label as NSString).draw(in: badge.insetBy(dx: 6, dy: 1), withAttributes: attributes)
            badges.append((badge, d.id))
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return badges.contains { $0.0.contains(local) } ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let badge = badges.last(where: { $0.0.contains(point) }) { onSelect?(badge.1) }
    }
    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }
}
