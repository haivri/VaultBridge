import SwiftUI

struct ConflictComparisonView: View {
    let detail: ConflictFileDetail
    @State private var comparison: ConflictComparison?
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What’s different").font(.headline)
            if let comparison {
                Text("− \(comparison.phoneOnlyCount) iPhone-only lines · + \(comparison.serverOnlyCount) server-only lines")
                    .font(.subheadline)
                Text("Choosing a whole version drops the other side’s unique lines. Neither side is necessarily newer.")
                    .font(.caption).foregroundStyle(.secondary)
                if comparison.phoneOnlyCount == 0 && comparison.serverOnlyCount == 0 {
                    Text("The text is identical. Check the filenames or deletion shown below.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comparison.rows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Text(lineLabel(row)).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                                Text(row.text.isEmpty ? " " : row.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption.monospaced())
                            .padding(.vertical, 4)
                            .background(row.kind == .phone ? Color.orange.opacity(0.15) : row.kind == .server ? Color.blue.opacity(0.15) : Color.clear)
                        }
                    }
                    .textSelection(.enabled)
                }
            } else if unavailable {
                Text("A text diff is unavailable for this attachment or unreadable file. Inspect the originals before choosing.")
            } else { ProgressView("Comparing originals…") }
        }
        .task(id: detail) {
            comparison = nil; unavailable = false
            guard detail.ours?.isBinary != true, detail.theirs?.isBinary != true,
                  let phone = text(detail.ours), let server = text(detail.theirs) else {
                unavailable = true; return
            }
            let result = await Task.detached(priority: .userInitiated) {
                ConflictComparison(phone: phone, server: server)
            }.value
            guard !Task.isCancelled else { return }
            comparison = result
        }
    }

    private func text(_ side: ConflictFileSide?) -> String? {
        guard let side else { return "" }
        return side.content.flatMap { String(data: $0, encoding: .utf8) }
    }
    private func lineLabel(_ row: ConflictComparison.Row) -> String {
        switch row.kind {
        case .phone: return "− P\(row.phoneLine!)"
        case .server: return "+ S\(row.serverLine!)"
        case .context: return "\(row.phoneLine!):\(row.serverLine!)"
        case .omitted: return "⋯"
        }
    }
}
