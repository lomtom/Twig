import Foundation

struct SourceLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, added, removed }
    let id: Int
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    let kind: Kind
}

struct SourcePreview {
    var id = UUID()
    let lines: [SourceLine]
    let notice: String?
    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }

    static func message(_ text: String) -> SourcePreview { SourcePreview(lines: [], notice: text) }

    static func source(_ text: String, added: Bool, notice: String? = nil) -> SourcePreview {
        var contents = text.components(separatedBy: "\n")
        if contents.last == "" { contents.removeLast() }
        let rows = contents.enumerated().map { index, line in
            SourceLine(id: index, text: line, oldNumber: added ? nil : index + 1, newNumber: index + 1, kind: added ? .added : .context)
        }
        return limited(rows, notice: notice)
    }

    // A full-context Git patch retains the current file plus deleted lines inline.
    // Headers and hunk markers are metadata, never source code.
    static func patch(_ text: String) -> SourcePreview? {
        var rows: [SourceLine] = []
        var old = 0, new = 0
        var inHunk = false
        var missingNewline = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("@@ ") {
                let tokens = line.split(separator: " ")
                guard tokens.count >= 3,
                      let oldStart = tokens[1].dropFirst().split(separator: ",").first.flatMap({ Int($0) }),
                      let newStart = tokens[2].dropFirst().split(separator: ",").first.flatMap({ Int($0) }) else { continue }
                old = oldStart; new = newStart; inHunk = true
                continue
            }
            if line.hasPrefix("diff --git ") { inHunk = false; continue }
            guard inHunk, let prefix = line.first else { continue }
            if prefix == "\\" { missingNewline = true; continue }
            let kind: SourceLine.Kind
            let left: Int?, right: Int?
            switch prefix {
            case " ": kind = .context; left = old; right = new; old += 1; new += 1
            case "+": kind = .added; left = nil; right = new; new += 1
            case "-": kind = .removed; left = old; right = nil; old += 1
            default: continue
            }
            rows.append(SourceLine(id: rows.count, text: String(line.dropFirst()), oldNumber: left, newNumber: right, kind: kind))
        }
        guard !rows.isEmpty else { return nil }
        return limited(rows, notice: missingNewline ? "当前或原始文件末尾没有换行符。" : nil)
    }

    private static func limited(_ rows: [SourceLine], notice: String?) -> SourcePreview {
        let limit = 20_000
        let message = rows.count > limit ? "文件过长，仅展示前 20,000 行，增删计数仅包含已显示部分。" : notice
        return SourcePreview(lines: Array(rows.prefix(limit)), notice: message)
    }
}

struct ChangeTreeNode: Identifiable {
    let path: String
    let name: String
    var file: ChangedFile?
    var children: [ChangeTreeNode] = []
    var id: String { (file == nil ? "directory:" : "file:") + path }
    var files: [ChangedFile] { file.map { [$0] } ?? children.flatMap(\.files) }

    static func build(_ files: [ChangedFile]) -> [ChangeTreeNode] {
        var root = ChangeTreeNode(path: "", name: "")
        for file in files { root.insert(file, components: file.path.split(separator: "/").map(String.init)[...]) }
        root.sort()
        return root.children
    }

    private mutating func insert(_ file: ChangedFile, components: ArraySlice<String>) {
        guard let name = components.first else { return }
        let childPath = path.isEmpty ? name : path + "/" + name
        if components.count == 1 { children.append(ChangeTreeNode(path: childPath, name: name, file: file)); return }
        let index: Int
        if let existing = children.firstIndex(where: { $0.name == name && $0.file == nil }) { index = existing }
        else { children.append(ChangeTreeNode(path: childPath, name: name)); index = children.count - 1 }
        children[index].insert(file, components: components.dropFirst())
    }

    private mutating func sort() {
        for index in children.indices { children[index].sort() }
        children.sort {
            if ($0.file == nil) != ($1.file == nil) { return $0.file == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
