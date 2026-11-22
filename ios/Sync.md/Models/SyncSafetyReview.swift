import Foundation

nonisolated struct SyncSafetyReview: Codable, Equatable, Sendable {
    struct Detail: Codable, Equatable, Sendable {
        let path: String
        let reason: String
        let removed: [String]
    }
    let paths: [String]
    let fingerprint: String
    var details: [Detail]? = nil
}

nonisolated enum ProtectedNoteText {
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw LocalGitError.repositoryCorrupted("This protected note cannot be previewed safely. Review its whole-file version.")
        }
        return text
    }
    static func lines(_ text: String) -> [String] { text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }
    static func missing(expected: String, current: String) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines(current) { counts[line, default: 0] += 1 }
        return lines(expected).filter { line in
            if counts[line, default: 0] > 0 { counts[line, default: 0] -= 1; return false }
            return !line.isEmpty
        }
    }
}

struct NoteRecoveryPreview: Sendable {
    let path: String
    let commit: String
    let fingerprint: String
    let current: String
    let historical: String
    var draft: ConflictMergeDraft { ConflictMergeDraft(phone: current, server: historical) }
}
