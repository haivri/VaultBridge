import Foundation

/// Plain-language action selected from repository state. Git terminology stays
/// available as supporting text, but the primary label describes the outcome.
enum VaultBridgePrimaryAction: String, Equatable, Sendable {
    case saveOnPhone
    case getServerUpdates
    case uploadSavedChanges
    case combineChanges
    case resolveConflicts
    case checkAgain

    static func choose(changeCount: Int, syncState: RepoSyncState, conflictCount: Int) -> Self {
        if conflictCount > 0 { return .resolveConflicts }
        if changeCount > 0 { return .saveOnPhone }
        switch syncState {
        case .behind: return .getServerUpdates
        case .ahead: return .uploadSavedChanges
        case .diverged: return .combineChanges
        case .upToDate, .unknown: return .checkAgain
        }
    }

    var title: String {
        switch self {
        case .saveOnPhone: "Save on This iPhone"
        case .getServerUpdates: "Get Server Updates"
        case .uploadSavedChanges: "Upload Saved Changes"
        case .combineChanges: "Combine Phone & Server Changes"
        case .resolveConflicts: "Resolve Conflicts"
        case .checkAgain: "Check Again"
        }
    }

    var gitSubtitle: String {
        switch self {
        case .saveOnPhone: "Create a restore point on this phone. Does not upload."
        case .getServerUpdates: "Bring newer server files onto this phone when there is no competing phone history."
        case .uploadSavedChanges: "Send this phone’s saved restore points to the server. Never force-overwrites."
        case .combineChanges: "Save the phone first, then safely combine both histories. Does not upload."
        case .resolveConflicts: "For each disputed file, choose the phone copy, server copy, or an edited combination."
        case .checkAgain: "Check phone files and refresh the known phone-versus-server state."
        }
    }

    var systemImage: String {
        switch self {
        case .saveOnPhone: "internaldrive.fill"
        case .getServerUpdates: "arrow.down.circle.fill"
        case .uploadSavedChanges: "arrow.up.circle.fill"
        case .combineChanges: "arrow.triangle.branch"
        case .resolveConflicts: "exclamationmark.triangle.fill"
        case .checkAgain: "arrow.clockwise.circle.fill"
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
