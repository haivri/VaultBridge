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

/// A preview only: independent edits are combined using the common ancestor;
/// overlapping edits still require a choice before the user explicitly saves.
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

    init(phone: String, server: String, ancestor: String? = nil) {
        if let ancestor {
            blocks = Self.threeWayBlocks(base: ancestor, phone: phone, server: server)
            return
        }
        // Add/add conflicts or unavailable ancestors cannot establish which
        // version changed. Keep the conservative, explicit two-way choices.
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

    private struct Edit {
        let range: Range<Int>
        let lines: [String]
        let phone: Bool
    }

    private static func edits(from base: [String], to version: [String], phone: Bool) -> [Edit] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in version.difference(from: base) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Edit] = []
        var i = 0, j = 0
        while i < base.count || j < version.count {
            let start = i
            var replacement: [String] = []
            while i < base.count && removed.contains(i) { i += 1 }
            while j < version.count && inserted.contains(j) { replacement.append(version[j]); j += 1 }
            if i != start || !replacement.isEmpty {
                result.append(Edit(range: start..<i, lines: replacement, phone: phone))
            } else {
                i += 1; j += 1
            }
        }
        return result
    }

    private static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty && b.isEmpty { return a.lowerBound == b.lowerBound }
        // An insertion exactly before/after a replacement can coexist with it.
        if a.isEmpty { return b.lowerBound < a.lowerBound && a.lowerBound < b.upperBound }
        if b.isEmpty { return a.lowerBound < b.lowerBound && b.lowerBound < a.upperBound }
        return a.overlaps(b)
    }

    private static func threeWayBlocks(base: String, phone: String, server: String) -> [Block] {
        let original = base.components(separatedBy: "\n")
        let edits = (edits(from: original, to: phone.components(separatedBy: "\n"), phone: true)
            + edits(from: original, to: server.components(separatedBy: "\n"), phone: false))
            .sorted {
                if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
                return $0.range.upperBound < $1.range.upperBound
            }
        var result: [Block] = []
        func append(_ left: [String], _ right: [String], shared: Bool) {
            result.append(Block(id: result.count, phone: left, server: right, shared: shared))
        }
        func render(_ group: [Edit], in range: Range<Int>) -> [String] {
            var lines: [String] = [], cursor = range.lowerBound
            for edit in group {
                lines += original[cursor..<edit.range.lowerBound]
                lines += edit.lines
                cursor = edit.range.upperBound
            }
            lines += original[cursor..<range.upperBound]
            return lines
        }
        var cursor = 0, index = 0
        while index < edits.count {
            var group = [edits[index]]
            var range = edits[index].range
            index += 1
            while index < edits.count && overlaps(range, edits[index].range) {
                group.append(edits[index])
                range = range.lowerBound..<max(range.upperBound, edits[index].range.upperBound)
                index += 1
            }
            if cursor < range.lowerBound {
                let context = Array(original[cursor..<range.lowerBound])
                append(context, context, shared: true)
            }
            let before = Array(original[range])
            let left = render(group.filter(\.phone), in: range)
            let right = render(group.filter { !$0.phone }, in: range)
            if left == right {
                append(left, left, shared: true)
            } else if left == before {
                append(right, right, shared: true)
            } else if right == before {
                append(left, left, shared: true)
            } else {
                append(left, right, shared: false)
            }
            cursor = range.upperBound
        }
        if cursor < original.count {
            let context = Array(original[cursor...])
            append(context, context, shared: true)
        }
        return result
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
