import Foundation

struct SourceRollbackContext: Equatable {
    let expected: RepositorySnapshot
    let file: ChangedFile
    let worktree: Data
    let indexEntry: Data
    let original: String
}

struct SourceChange: Identifiable, Equatable {
    let id: Int
    let displayRows: Range<Int>
    let oldLines: Range<Int>
    let worktreeRange: NSRange
    let original: String
}

extension SourcePreview {
    var changes: [SourceChange] {
        var output: [SourceChange] = []
        var row = 0, oldLine = 0, newOffset = 0
        while row < lines.count {
            if lines[row].kind == .context {
                oldLine += 1; newOffset += (lines[row].content as NSString).length; row += 1
                continue
            }
            let start = row, oldStart = oldLine, newStart = newOffset
            var original = ""
            while row < lines.count, lines[row].kind != .context {
                let line = lines[row]
                if line.kind == .removed { original += line.content; oldLine += 1 }
                else { newOffset += (line.content as NSString).length }
                row += 1
            }
            output.append(SourceChange(id: start, displayRows: start..<row, oldLines: oldStart..<oldLine,
                worktreeRange: NSRange(location: newStart, length: newOffset - newStart), original: original))
        }
        return output
    }
}
