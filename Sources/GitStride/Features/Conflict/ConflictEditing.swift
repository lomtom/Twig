import AppKit

/// Line anchors are shared by highlighting, navigation and synchronized scrolling.
struct ConflictLineMap {
    struct Block {
        let source: Range<Int>
        let result: Range<Int>
    }
    let blocks: [Block]
    let sourceCount: Int
    let resultCount: Int
    let sourceChanges: Set<Int>
    let resultChanges: Set<Int>
    private let sourceOffsets: [Int]
    private let resultOffsets: [Int]
    private let sourceLength: Int
    private let resultLength: Int

    init(source: String, result: String) {
        let sourceLines = source.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        // Include terminators in equality so accepting an EOF insertion never
        // concatenates it onto a preceding line that lacks a newline.
        let a = sourceLines.enumerated().map { $0.element + ($0.offset < sourceLines.count - 1 ? "\n" : "") }
        let b = resultLines.enumerated().map { $0.element + ($0.offset < resultLines.count - 1 ? "\n" : "") }
        sourceCount = a.count; resultCount = b.count
        func offsets(_ lines: [String]) -> [Int] {
            var position = 0
            return lines.map { line in
                defer { position += (line as NSString).length + 1 }
                return position
            }
        }
        sourceOffsets = offsets(sourceLines); resultOffsets = offsets(resultLines)
        sourceLength = (source as NSString).length; resultLength = (result as NSString).length
        var matches: [(Int, Int)] = []
        // Patience anchors avoid quadratic work for large files. Small repeated-line
        // regions use CollectionDifference to retain matches inside each region.
        func match(_ ar: Range<Int>, _ br: Range<Int>) {
            guard !Task.isCancelled else { return }
            var x = ar.lowerBound, y = br.lowerBound
            while x < ar.upperBound, y < br.upperBound, a[x] == b[y] {
                matches.append((x, y)); x += 1; y += 1
            }
            var ae = ar.upperBound, be = br.upperBound
            while ae > x, be > y, a[ae - 1] == b[be - 1] { ae -= 1; be -= 1 }
            if x < ae, y < be {
                var ac: [String: [Int]] = [:], bc: [String: [Int]] = [:]
                for i in x..<ae { ac[a[i], default: []].append(i) }
                for j in y..<be { bc[b[j], default: []].append(j) }
                let pairs = (x..<ae).compactMap { i -> (Int, Int)? in
                    guard ac[a[i]]?.count == 1, let js = bc[a[i]], js.count == 1 else { return nil }
                    return (i, js[0])
                }
                var tails: [Int] = [], previous = Array(repeating: -1, count: pairs.count)
                for i in pairs.indices {
                    var low = 0, high = tails.count
                    while low < high {
                        let mid = (low + high) / 2
                        if pairs[tails[mid]].1 < pairs[i].1 { low = mid + 1 } else { high = mid }
                    }
                    if low > 0 { previous[i] = tails[low - 1] }
                    if low == tails.count { tails.append(i) } else { tails[low] = i }
                }
                var anchors: [(Int, Int)] = []
                var cursor = tails.last ?? -1
                while cursor >= 0 { anchors.append(pairs[cursor]); cursor = previous[cursor] }
                if !anchors.isEmpty {
                    for (i, j) in anchors.reversed() {
                        match(x..<i, y..<j); matches.append((i, j)); x = i + 1; y = j + 1
                    }
                    match(x..<ae, y..<be)
                } else if (ae - x) * (be - y) <= 250_000 {
                    let aa = Array(a[x..<ae]), bb = Array(b[y..<be])
                    let diff = bb.difference(from: aa)
                    var removed = Set<Int>(), inserted = Set<Int>()
                    for change in diff {
                        switch change {
                        case .remove(let i, _, _): removed.insert(i)
                        case .insert(let j, _, _): inserted.insert(j)
                        }
                    }
                    let ai = aa.indices.filter { !removed.contains($0) }
                    let bi = bb.indices.filter { !inserted.contains($0) }
                    matches += zip(ai, bi).map { (x + $0.0, y + $0.1) }
                } else {
                    // Monotone matching also preserves repeated unchanged lines without
                    // allocating a large edit-distance matrix.
                    var next = y
                    for i in x..<ae {
                        guard let positions = bc[a[i]] else { continue }
                        var low = 0, high = positions.count
                        while low < high {
                            let mid = (low + high) / 2
                            if positions[mid] < next { low = mid + 1 } else { high = mid }
                        }
                        if low < positions.count { matches.append((i, positions[low])); next = positions[low] + 1 }
                    }
                }
            }
            for offset in 0..<(ar.upperBound - ae) { matches.append((ae + offset, be + offset)) }
        }
        match(a.indices, b.indices)
        var hunks: [Block] = [], x = 0, y = 0
        for (i, j) in matches + [(a.count, b.count)] {
            if x < i || y < j { hunks.append(Block(source: x..<i, result: y..<j)) }
            x = i + 1; y = j + 1
        }
        blocks = hunks
        sourceChanges = Set(hunks.flatMap { Array($0.source) })
        resultChanges = Set(hunks.flatMap { Array($0.result) })
    }

    func resultRange(forLines lines: Range<Int>) -> NSRange {
        let start = lines.lowerBound < resultOffsets.count ? resultOffsets[lines.lowerBound] : resultLength
        let end = lines.upperBound < resultOffsets.count ? resultOffsets[lines.upperBound] : resultLength
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Exact boundaries for a union of complete diff hunks, including insertions
    /// whose result range is empty. Interpolated scroll positions must not be used
    /// to choose replacement text.
    func sourceRange(forLines lines: Range<Int>) -> NSRange {
        func boundary(_ line: Int, trailing: Bool) -> Int {
            var offset = 0
            for block in blocks {
                if line < block.result.lowerBound { break }
                if line == block.result.lowerBound {
                    if block.result.isEmpty && trailing { return block.source.upperBound }
                    return block.source.lowerBound
                }
                if line < block.result.upperBound {
                    return trailing ? block.source.upperBound : block.source.lowerBound
                }
                offset = block.source.upperBound - block.result.upperBound
            }
            return max(0, min(sourceCount, line + offset))
        }
        let first = boundary(lines.lowerBound, trailing: false)
        let last = boundary(lines.upperBound, trailing: lines.isEmpty)
        let start = first < sourceOffsets.count ? sourceOffsets[first] : sourceLength
        let end = last < sourceOffsets.count ? sourceOffsets[last] : sourceLength
        return NSRange(location: start, length: max(0, end - start))
    }

    func sourceRange(forResult range: NSRange) -> NSRange {
        func line(at offset: Int) -> Int {
            var low = 0, high = resultOffsets.count
            while low < high {
                let mid = (low + high) / 2
                if resultOffsets[mid] <= offset { low = mid + 1 } else { high = mid }
            }
            return max(0, low - 1)
        }
        let first = line(at: min(range.location, resultLength))
        let last = line(at: min(max(range.location, NSMaxRange(range) - 1), resultLength))
        let lower = min(sourceCount - 1, max(0, Int(sourceLine(forResult: CGFloat(first)))))
        let upper = min(sourceCount, max(lower + 1, Int(ceil(sourceLine(forResult: CGFloat(last + 1))))))
        let start = sourceOffsets[lower]
        let end = upper < sourceCount ? sourceOffsets[upper] : sourceLength
        return NSRange(location: start, length: range.length == 0 ? 0 : max(0, end - start))
    }

    func sourceLine(forResult line: CGFloat) -> CGFloat { map(line, reverse: false) }
    func resultLine(forSource line: CGFloat) -> CGFloat { map(line, reverse: true) }
    private func map(_ line: CGFloat, reverse: Bool) -> CGFloat {
        var offset: CGFloat = 0
        for block in blocks {
            let from = reverse ? block.source : block.result
            let to = reverse ? block.result : block.source
            if line < CGFloat(from.lowerBound) { break }
            if line < CGFloat(from.upperBound), !from.isEmpty {
                return CGFloat(to.lowerBound) + (line - CGFloat(from.lowerBound)) * CGFloat(to.count) / CGFloat(from.count)
            }
            offset = CGFloat(to.upperBound - from.upperBound)
        }
        return max(0, min(CGFloat(reverse ? resultCount : sourceCount), line + offset))
    }
}

struct ConflictComparison {
    let ours: ConflictLineMap
    let theirs: ConflictLineMap
    static func make(result: String, document: ConflictDocument) -> Self {
        Self(ours: .init(source: document.ours?.text ?? "", result: result),
             theirs: .init(source: document.theirs?.text ?? "", result: result))
    }
}

struct EditableConflict: Identifiable {
    enum Choice: String { case unresolved = "待处理", left = "已采用左侧", right = "已采用右侧", manual = "已手动处理" }
    var id: Int
    var number: Int = 0
    var isConflict = true
    var leftRange: NSRange? = nil
    var rightRange: NSRange? = nil
    var title: String { "\(isConflict ? "冲突" : "差异") #\(number + 1)" }
    var status: String { !isConflict && choice == .unresolved ? "保留当前结果" : choice.rawValue }
    var range: NSRange
    let ours: String
    let theirs: String
    var choice: Choice = .unresolved
    var canReplace = true
}

extension EditableConflict {
    static func make(document: ConflictDocument, comparison: ConflictComparison) -> [Self] {
        let text = document.initialText
        var output = MergeChunk.parse(text).map {
            Self(id: $0.id, number: $0.id, range: NSRange($0.range, in: text), ours: $0.ours, theirs: $0.theirs)
        }
        // A missing stage represents deletion of the file, not an empty text
        // region. Keep that operation in the explicit whole-file resolution menu.
        guard document.canEdit, document.ours?.text != nil, document.theirs?.text != nil else { return output }
        let conflictRanges = output.map(\.range)
        let hunks: [ConflictLineMap.Block] = comparison.ours.blocks + comparison.theirs.blocks
        let lineRanges: [Range<Int>] = hunks.map { $0.result }
        var candidates: [Range<Int>] = lineRanges.filter { lines in
            let range = comparison.ours.resultRange(forLines: lines)
            return !conflictRanges.contains { conflict in
                if range.length == 0 { return range.location >= conflict.location && range.location < NSMaxRange(conflict) }
                return NSIntersectionRange(range, conflict).length > 0
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound { return lhs.upperBound < rhs.upperBound }
            return lhs.lowerBound < rhs.lowerBound
        }
        var groups: [Range<Int>] = []
        for candidate in candidates {
            if let last = groups.last, (candidate.lowerBound < last.upperBound || candidate.lowerBound == last.lowerBound) {
                groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, candidate.upperBound)
            } else { groups.append(candidate) }
        }
        let left = (document.ours?.text ?? "") as NSString
        let right = (document.theirs?.text ?? "") as NSString
        for lines in groups {
            let leftRange = comparison.ours.sourceRange(forLines: lines)
            let rightRange = comparison.theirs.sourceRange(forLines: lines)
            let ours = left.substring(with: leftRange), theirs = right.substring(with: rightRange)
            let range = comparison.ours.resultRange(forLines: lines)
            // A manual result differing from both identical sources is also selectable.
            if ours == theirs && ours == (text as NSString).substring(with: range) { continue }
            output.append(Self(id: 0, isConflict: false, leftRange: leftRange, rightRange: rightRange,
                               range: range, ours: ours, theirs: theirs))
        }
        output.sort { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
        var differenceNumber = 0
        for i in output.indices {
            output[i].id = i
            if !output[i].isConflict { output[i].number = differenceNumber; differenceNumber += 1 }
        }
        return output
    }
}

@MainActor final class ConflictEditingSession: ObservableObject {
    struct Snapshot {
        var text: String
        var blocks: [EditableConflict]
        var selected: Int?
    }
    @Published private(set) var snapshot = Snapshot(text: "", blocks: [], selected: nil)
    @Published private(set) var navigation = UUID()
    @Published private(set) var historyRevision = 0
    let history = UndoManager()
    var text: String { snapshot.text }
    var blocks: [EditableConflict] { snapshot.blocks }
    var conflicts: [EditableConflict] { blocks.filter(\.isConflict) }
    var selected: EditableConflict? { blocks.first { $0.id == snapshot.selected } }
    var remaining: Int { conflicts.filter { $0.choice == .unresolved }.count }
    init() { history.levelsOfUndo = 100; history.groupsByEvent = false }

    func load(_ text: String, blocks: [EditableConflict]) {
        snapshot = Snapshot(text: text, blocks: blocks, selected: blocks.first?.id)
        history.removeAllActions(); historyRevision += 1; navigation = UUID()
    }
    func select(_ id: Int) { snapshot.selected = id; navigation = UUID() }
    func move(_ step: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == snapshot.selected }), !blocks.isEmpty else { return }
        select(blocks[min(max(0, index + step), blocks.count - 1)].id)
    }
    private func restore(_ value: Snapshot) {
        let old = snapshot
        history.registerUndo(withTarget: self) { $0.restore(old) }
        snapshot = value; historyRevision += 1
    }
    private func record(_ name: String) {
        let old = snapshot
        history.beginUndoGrouping()
        history.registerUndo(withTarget: self) { $0.restore(old) }
        history.setActionName(name)
        history.endUndoGrouping()
        historyRevision += 1
    }
    func undo() { history.undo(); historyRevision += 1 }
    func redo() { history.redo(); historyRevision += 1 }

    func edit(_ newText: String) {
        guard newText != text else { return }
        record("编辑合并结果")
        let old = Array(text.utf16), new = Array(newText.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        adjust(NSRange(location: prefix, length: old.count - prefix - suffix), replacementLength: new.count - prefix - suffix, target: nil)
        snapshot.text = newText
        for i in snapshot.blocks.indices {
            let c = snapshot.blocks[i]
            let content = (newText as NSString).substring(with: c.range)
            if MergeChunk.containsMarkers(content) { snapshot.blocks[i].choice = .unresolved }
        }
    }
    // Boundary affinity keeps adjacent conflicts separate, including empty resolutions.
    private func adjust(_ edit: NSRange, replacementLength: Int, target: Int?) {
        let delta = replacementLength - edit.length
        let insertionOwner: Int? = target == nil && edit.length == 0
            ? (blocks.first { $0.range.length == 0 && $0.range.location == edit.location }?.id
                ?? blocks.first { $0.range.location <= edit.location && edit.location < NSMaxRange($0.range) }?.id)
            : nil
        for i in snapshot.blocks.indices {
            let c = snapshot.blocks[i], start = c.range.location, end = NSMaxRange(c.range)
            if let insertionOwner, c.id != insertionOwner, start >= edit.location {
                snapshot.blocks[i].range.location += delta
            } else if c.id == target {
                snapshot.blocks[i].range = NSRange(location: edit.location, length: replacementLength)
            } else if let target, c.range.length == 0, start == edit.location {
                if c.id > target { snapshot.blocks[i].range.location += delta }
            } else if end <= edit.location && !(c.range.length == 0 && start == edit.location && target == nil) {
                continue
            } else if start >= NSMaxRange(edit) && !(edit.length == 0 && start == edit.location && target == nil) {
                snapshot.blocks[i].range.location += delta
            } else {
                if edit.location < start || NSMaxRange(edit) > end {
                    // A manual edit spanning boundaries no longer has an unambiguous
                    // replacement region. Preserve it and require manual confirmation.
                    snapshot.blocks[i].canReplace = false
                }
                let lower = min(start, edit.location)
                let upper = max(edit.location + replacementLength, end + delta)
                snapshot.blocks[i].range = NSRange(location: lower, length: max(0, upper - lower))
                snapshot.blocks[i].choice = .unresolved
            }
        }
    }
    func accept(_ id: Int, choice: EditableConflict.Choice) {
        guard let c = blocks.first(where: { $0.id == id }), c.canReplace, c.choice != .left, c.choice != .right else { return }
        record("处理\(c.title)")
        snapshot.selected = id
        replace(c, choice: choice)
        // Keep the adopted difference selected for review; undo restores its actions.
        if c.isConflict {
            snapshot.selected = conflicts.first(where: { $0.id > id && $0.choice == .unresolved })?.id
                ?? conflicts.first(where: { $0.choice == .unresolved })?.id ?? id
        }
        navigation = UUID()
    }
    private func replace(_ c: EditableConflict, choice: EditableConflict.Choice) {
        let value: String
        switch choice {
        case .left: value = c.ours
        case .right: value = c.theirs
        case .manual, .unresolved: return
        }
        let output = (text as NSString).replacingCharacters(in: c.range, with: value)
        adjust(c.range, replacementLength: (value as NSString).length, target: c.id)
        snapshot.text = output
        if let i = snapshot.blocks.firstIndex(where: { $0.id == c.id }) { snapshot.blocks[i].choice = choice }
    }
    func markManual(_ id: Int) {
        guard let i = blocks.firstIndex(where: { $0.id == id }),
              !MergeChunk.containsMarkers((text as NSString).substring(with: blocks[i].range)) else { return }
        record("确认手动处理")
        snapshot.blocks[i].choice = .manual
    }
}
