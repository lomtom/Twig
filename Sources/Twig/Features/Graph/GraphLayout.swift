// Adapted in Swift from the IntelliJ graph layout/print pipeline used by
// DetachHead/rebased. Copyright 2000-2024 JetBrains s.r.o. and contributors.
// Licensed under Apache-2.0; see ThirdPartyNotices/rebased.md.
import Foundation

struct GraphLaneLayout {
    let rows: [GraphLaneRow]
    let laneCount: Int

    private struct Edge {
        let source: Int
        let target: Int?
        let rank: Int
        let color: Int
    }
    private enum Element {
        case node(Int)
        case edge(Int)
    }

    static func make(commits: [GraphCommit], showLongEdges: Bool = false) -> GraphLaneLayout {
        guard !commits.isEmpty else { return GraphLaneLayout(rows: [], laneCount: 1) }
        let count = commits.count
        var index: [String: Int] = [:]
        for (row, commit) in commits.enumerated() { index[commit.oid] = row }
        let parents = commits.enumerated().map { row, commit in
            var seen = Set<String>()
            return commit.parents.filter { seen.insert($0).inserted }.map { oid in
                index[oid].flatMap { $0 > row ? $0 : nil }
            }
        }
        let ancestors = Set(parents.flatMap { $0.compactMap { $0 } })
        // HEAD gets the leftmost spine. Other graph heads retain log order.
        let heads = commits.indices.filter { !ancestors.contains($0) || commits[$0].references.contains { $0.kind == .head } }
            .sorted {
                let a = commits[$0].references.contains { $0.kind == .head }
                let b = commits[$1].references.contains { $0.kind == .head }
                return a == b ? $0 < $1 : a
            }
        var ranks = Array(repeating: 0, count: count)
        var nextRank = 1
        // Iterative DFS: keep the first-parent chain together; allocate a new
        // layout index only when a previously unvisited path reaches its end.
        for head in heads + Array(commits.indices) where ranks[head] == 0 {
            var stack = [head]
            while let node = stack.last {
                let firstVisit = ranks[node] == 0
                if firstVisit { ranks[node] = nextRank }
                if let parent = parents[node].compactMap({ $0 }).first(where: { ranks[$0] == 0 }) {
                    stack.append(parent)
                } else {
                    if firstVisit { nextRank += 1 }
                    stack.removeLast()
                }
            }
        }
        var edges: [Edge] = []
        var starts = Array(repeating: [Int](), count: count)
        for source in commits.indices {
            for target in parents[source] {
                let rank = max(ranks[source], target.map { ranks[$0] } ?? ranks[source])
                starts[source].append(edges.count)
                edges.append(Edge(source: source, target: target, rank: rank, color: rank - 1))
            }
        }
        func compareEdgeToNode(_ edgeID: Int, _ node: Int) -> Int {
            let edge = edges[edgeID]
            if edge.rank != ranks[node] { return edge.rank - ranks[node] }
            return edge.source - node
        }
        // Compare edges where their lifetimes first overlap, rather than by
        // their current screen column. This preserves order through merges.
        func compare(_ lhs: Element, _ rhs: Element) -> Int {
            switch (lhs, rhs) {
            case let (.node(a), .node(b)): return a - b
            case let (.edge(a), .node(b)): return compareEdgeToNode(a, b)
            case let (.node(a), .edge(b)): return -compareEdgeToNode(b, a)
            case let (.edge(a), .edge(b)):
                if a == b { return 0 }
                let first = edges[a], second = edges[b]
                let result: Int
                if first.source == second.source {
                    let downA = first.target ?? count, downB = second.target ?? count
                    if downA == downB { return a - b }
                    if downA < downB { result = -compareEdgeToNode(b, downA) }
                    else { result = compareEdgeToNode(a, downB) }
                } else if first.source < second.source {
                    result = compareEdgeToNode(a, second.source)
                } else {
                    result = -compareEdgeToNode(b, first.source)
                }
                return result == 0 ? a - b : result
            }
        }
        func visible(_ edge: Edge, at row: Int) -> Bool {
            guard let target = edge.target else { return row == edge.source + 1 }
            return showLongEdges || target - edge.source < 30 || row - edge.source <= 1 || target - row <= 1
        }
        var positions = Array(repeating: [Int: Int](), count: count)
        var nodes = Array(repeating: 0, count: count)
        var active = Set<Int>()
        var width = 1
        for row in commits.indices {
            active = active.filter { (edges[$0].target ?? (edges[$0].source + 2)) > row }
            var elements: [Element] = [.node(row)]
            elements += active.filter { visible(edges[$0], at: row) }.map(Element.edge)
            elements.sort { compare($0, $1) < 0 }
            for (column, element) in elements.enumerated() {
                switch element {
                case .node: nodes[row] = column
                case let .edge(id): positions[row][id] = column
                }
            }
            width = max(width, elements.count)
            active.formUnion(starts[row])
        }
        // Resolve each edge to either a passing edge slot or its real endpoint.
        // Both halves use the same midpoint at the row boundary, with no seams.
        var segments = Array(repeating: [GraphLaneSegment](), count: count)
        var arrows = Array(repeating: [GraphLaneArrow](), count: count)
        for (id, edge) in edges.enumerated() {
            let end = edge.target ?? min(edge.source + 1, count - 1)
            var previous: (row: Int, column: Int)?
            for row in edge.source...end {
                let column: Int?
                if row == edge.source || row == edge.target { column = nodes[row] }
                else { column = positions[row][id] }
                guard let column else { continue }
                if let last = previous {
                    if row == last.row + 1 {
                        let midpoint = Double(last.column + column) / 2
                        segments[last.row].append(GraphLaneSegment(from: Double(last.column), to: midpoint, color: edge.color, half: .outgoing))
                        segments[row].append(GraphLaneSegment(from: midpoint, to: Double(column), color: edge.color, half: .incoming))
                    } else {
                        arrows[last.row].append(GraphLaneArrow(lane: last.column, color: edge.color, pointsDown: true))
                        arrows[row].append(GraphLaneArrow(lane: column, color: edge.color, pointsDown: false))
                    }
                }
                previous = (row, column)
            }
            if edge.target == nil, let last = previous {
                arrows[last.row].append(GraphLaneArrow(lane: last.column, color: edge.color, pointsDown: true))
            }
        }
        let rows = commits.indices.map { row in
            GraphLaneRow(commit: commits[row], lane: nodes[row], nodeColor: ranks[row] - 1,
                         segments: segments[row], arrows: arrows[row])
        }
        return GraphLaneLayout(rows: rows, laneCount: width)
    }
}
