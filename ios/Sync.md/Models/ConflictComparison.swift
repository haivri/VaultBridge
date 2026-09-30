import Foundation

/// A compact comparison of the two originals, with unchanged runs collapsed.
struct ConflictComparison: Sendable {
    struct Row: Identifiable, Sendable {
        enum Kind: Sendable { case context, phone, server, omitted }
        let id: Int
        let kind: Kind
        let text: String
        let phoneLine: Int?
        let serverLine: Int?
    }
    let rows: [Row]
    let phoneOnlyCount: Int
    let serverOnlyCount: Int

    init(phone: String, server: String, context: Int = 2) {
        let a = phone.components(separatedBy: "\n")
        let b = server.components(separatedBy: "\n")
        let delta = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in delta {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        phoneOnlyCount = removed.count
        serverOnlyCount = inserted.count
        var all: [Row] = []
        var i = 0, j = 0
        func append(_ kind: Row.Kind, _ text: String, _ left: Int?, _ right: Int?) {
            all.append(Row(id: all.count, kind: kind, text: text, phoneLine: left, serverLine: right))
        }
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) {
                append(.phone, a[i], i + 1, nil); i += 1
            } else if j < b.count && inserted.contains(j) {
                append(.server, b[j], nil, j + 1); j += 1
            } else if i < a.count && j < b.count {
                append(.context, a[i], i + 1, j + 1); i += 1; j += 1
            } else { break }
        }
        if context >= all.count { rows = all; return }
        var visible = Set<Int>()
        for index in all.indices where all[index].kind != .context {
            for nearby in max(0, index - max(0, context))...min(all.count - 1, index + max(0, context)) {
                visible.insert(nearby)
            }
        }
        var compact: [Row] = []
        var hidden = 0
        func flushHidden() {
            if hidden > 0 {
                compact.append(Row(id: -compact.count - 1, kind: .omitted, text: "\(hidden) unchanged lines hidden", phoneLine: nil, serverLine: nil))
                hidden = 0
            }
        }
        for row in all {
            if visible.contains(row.id) { flushHidden(); compact.append(row) }
            else { hidden += 1 }
        }
        flushHidden()
        rows = compact
    }
}

/// Explicit choices for each differing block. Shared lines are always retained.
struct ConflictMergeDraft: Sendable {
    enum Choice: String, CaseIterable, Sendable { case phone = "iPhone", server = "Server", both = "Both" }
    struct Block: Identifiable, Sendable {
        let id: Int
        let phone: [String]
        let server: [String]
        let shared: Bool
    }
    let blocks: [Block]
    var changes: [Block] { blocks.filter { !$0.shared } }

    init(phone: String, server: String) {
        let rows = ConflictComparison(phone: phone, server: server, context: Int.max / 4).rows
        var result: [Block] = []
        var left: [String] = [], right: [String] = []
        var shared: Bool?
        func flush() {
            guard let shared else { return }
            result.append(Block(id: result.count, phone: left, server: right, shared: shared))
            left = []; right = []
        }
        for row in rows where row.kind != .omitted {
            let same = row.kind == .context
            if shared != same { flush(); shared = same }
            if row.kind == .phone || same { left.append(row.text) }
            if row.kind == .server || same { right.append(row.text) }
        }
        flush()
        blocks = result
    }

    func result(choices: [Int: Choice]) -> String? {
        var lines: [String] = []
        for block in blocks {
            if block.shared { lines += block.phone; continue }
            guard let choice = choices[block.id] else { return nil }
            switch choice {
            case .phone: lines += block.phone
            case .server: lines += block.server
            case .both: lines += block.phone + block.server
            }
        }
        return lines.joined(separator: "\n")
    }
}
