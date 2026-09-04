import Foundation

enum GitFileStatusKind: String, Codable, Sendable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case typeChanged
    case untracked
    case conflicted
}

struct GitStatusEntry: Identifiable, Codable, Sendable, Equatable {
    /// NFC-normalized for display and matching.
    let path: String
    let indexStatus: GitFileStatusKind?
    let workTreeStatus: GitFileStatusKind?
    let oldPath: String?
    /// The exact bytes libgit2 reports for the file as it exists on disk.
    /// Staging must use this form so the index converges on the spelling
    /// status compares against; `path` may differ from it byte-wise.
    let rawPath: String?

    init(
        path: String,
        indexStatus: GitFileStatusKind?,
        workTreeStatus: GitFileStatusKind?,
        oldPath: String? = nil,
        rawPath: String? = nil
    ) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.oldPath = oldPath
        self.rawPath = rawPath
    }

    /// Path to hand to per-path index operations.
    var stagingPath: String { rawPath ?? path }

    var id: String { path }

    var isConflicted: Bool {
        indexStatus == .conflicted || workTreeStatus == .conflicted
    }
}

enum RepoSyncState: String, Codable, Sendable {
    case upToDate
    case ahead
    case behind
    case diverged
    case unknown
}

enum PullPlanAction: String, Codable, Sendable {
    case upToDate
    case fastForward
    case blockedByLocalChanges
    case diverged
    case remoteBranchMissing
}

struct PullPlan: Codable, Sendable, Equatable {
    let action: PullPlanAction
    let branch: String
    let localCommitSHA: String
    let remoteCommitSHA: String
    let hasLocalChanges: Bool
    let aheadBy: Int
    let behindBy: Int
}

/// Most recent push failure for one repository, kept per-repo so status UI
/// never shows another repository's stale app-global error.
struct PushErrorState: Equatable, Sendable {
    let message: String
    /// True when the push was blocked because committed or staged large files
    /// are ordinary Git blobs — the condition the explicit LFS repair fixes.
    let isLFSRepairEligible: Bool
    let date: Date
}

/// Kind of the most recent repository action result shown to the user. The
/// name is historical: every foreground workflow (save, combine, upload,
/// restore) reports here so one line on screen always describes what just
/// happened. `tone` is what views should key colors and icons from.
enum PullOutcomeKind: String, Codable, Sendable {
    case upToDate
    case fastForwarded
    case rebased
    case rebaseConflicts
    case blockedByLocalChanges
    case diverged
    case remoteBranchMissing
    case failed
    /// Phone and server histories were combined with a merge commit.
    case merged
    /// A merge is waiting for the user to choose between phone and server copies.
    case mergeConflicts
    /// A local restore point was created. Nothing was uploaded.
    case saved
    /// A protected phone backup or sheltered edits were put back on disk.
    case restored
    /// The user or the system stopped the action before it finished.
    case cancelled

    enum Tone: Sendable {
        case success
        case info
        case attention
        case failure
        case neutral
    }

    var tone: Tone {
        switch self {
        case .upToDate, .fastForwarded, .rebased, .merged, .saved: .success
        case .restored: .info
        case .rebaseConflicts, .mergeConflicts, .blockedByLocalChanges, .diverged, .remoteBranchMissing: .attention
        case .failed: .failure
        case .cancelled: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .upToDate:              "checkmark.circle.fill"
        case .fastForwarded:         "arrow.down.circle.fill"
        case .rebased, .merged:      "arrow.triangle.merge"
        case .saved:                 "internaldrive.fill"
        case .restored:              "arrow.uturn.backward.circle.fill"
        case .rebaseConflicts, .mergeConflicts, .blockedByLocalChanges: "exclamationmark.triangle.fill"
        case .diverged:              "arrow.triangle.branch"
        case .remoteBranchMissing:   "questionmark.circle.fill"
        case .failed:                "xmark.circle.fill"
        case .cancelled:             "minus.circle"
        }
    }
}

struct PullOutcomeState: Codable, Sendable, Equatable {
    let kind: PullOutcomeKind
    let message: String
    let date: Date
}
