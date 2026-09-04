import Foundation

/// The one button on the normal vault screen. VaultBridge runs the whole
/// safe workflow itself (save, compare, combine, upload, verify); the button
/// only changes when the machine cannot proceed without a human choice.
enum VaultBridgePrimaryAction: String, Equatable, Sendable {
    case syncNow
    case resolveConflicts

    static func choose(conflictCount: Int) -> Self {
        conflictCount > 0 ? .resolveConflicts : .syncNow
    }

    var title: String {
        switch self {
        case .syncNow: "Sync Now"
        case .resolveConflicts: "Resolve Conflicts"
        }
    }

    var subtitle: String {
        switch self {
        case .syncNow: "Saves this phone, brings in server changes, combines if needed, uploads, and verifies."
        case .resolveConflicts: "Some notes changed on both sides. Choose the phone copy, the server copy, or an edited combination."
        }
    }

    var systemImage: String {
        switch self {
        case .syncNow: "arrow.triangle.2.circlepath"
        case .resolveConflicts: "exclamationmark.triangle.fill"
        }
    }
}

struct GitRecoverySnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let referenceName: String
    let commitSHA: String
    let stashMessage: String?

    init(referenceName: String, commitSHA: String, stashMessage: String? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.referenceName = referenceName
        self.commitSHA = commitSHA
        self.stashMessage = stashMessage
    }
}

/// Edits that were moved into a stash so a combine or replacement could run
/// on a clean working tree, and that have not been put back yet. Persisted so
/// they survive an app restart and are never silently forgotten.
struct VaultBridgeShelteredEdits: Codable, Equatable, Sendable {
    let stashMessage: String
    let createdAt: Date
    let reason: String

    init(stashMessage: String, reason: String, createdAt: Date = Date()) {
        self.stashMessage = stashMessage
        self.reason = reason
        self.createdAt = createdAt
    }
}
