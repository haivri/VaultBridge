import Foundation

nonisolated struct SyncSafetyReview: Codable, Equatable, Sendable {
    let paths: [String]
    let fingerprint: String
}
