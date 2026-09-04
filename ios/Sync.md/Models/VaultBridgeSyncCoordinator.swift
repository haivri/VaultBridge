import Foundation
import UserNotifications

enum VaultBridgeLocalNotifications {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Uses one replaceable request per vault so repeated attention states do
    /// not build a notification backlog. Bodies deliberately omit Git errors,
    /// file names, remote URLs, and local paths.
    static func post(repo: RepoConfig, needsAttention: Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = needsAttention ? "VaultBridge needs attention" : "VaultBridge sync complete"
        content.body = needsAttention
            ? "Open VaultBridge to review \(repo.displayName)."
            : "\(repo.displayName) is safely up to date."
        content.sound = .default
        let identifier = "vaultbridge.sync.\(repo.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

enum VaultBridgeSyncPhase: String, Codable, Sendable {
    case idle
    case inspecting
    case committing
    case fetching
    case comparing
    case reconciling
    case pulling
    case pushing
    case verifying
    case complete
    case attention
    case failed
}

struct VaultBridgeSyncStatus: Equatable, Sendable {
    var phase: VaultBridgeSyncPhase = .idle
    var message: String = "Ready"
    var date: Date?

    var isRunning: Bool {
        switch phase {
        case .inspecting, .committing, .fetching, .comparing, .reconciling, .pulling, .pushing, .verifying: true
        default: false
        }
    }
}

struct VaultBridgeSyncJournalEntry: Codable, Sendable {
    let repoID: UUID
    let repoName: String
    let phase: VaultBridgeSyncPhase
    let message: String
    let date: Date
    /// Optional additions preserve decoding of journals written by 0.4.x.
    let runID: UUID?
    let mode: String?
    let progress: Int?
    let checkpointSHA: String?

    init(
        repoID: UUID,
        repoName: String,
        phase: VaultBridgeSyncPhase,
        message: String,
        date: Date,
        runID: UUID? = nil,
        mode: String? = nil,
        progress: Int? = nil,
        checkpointSHA: String? = nil
    ) {
        self.repoID = repoID
        self.repoName = repoName
        self.phase = phase
        self.message = message
        self.date = date
        self.runID = runID
        self.mode = mode
        self.progress = progress
        self.checkpointSHA = checkpointSHA
    }
}

/// A tiny durable journal makes interrupted foreground work diagnosable. It
/// records intent and outcome only; credentials and vault contents never enter it.
actor VaultBridgeSyncJournal {
    static let shared = VaultBridgeSyncJournal()

    private let fileURL: URL
    private var entriesByRepo: [UUID: VaultBridgeSyncJournalEntry]

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("VaultBridge", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("sync-journal.json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.entriesByRepo = (try? Data(contentsOf: self.fileURL))
            .flatMap { try? decoder.decode([UUID: VaultBridgeSyncJournalEntry].self, from: $0) }
            ?? [:]
    }

    func record(_ entry: VaultBridgeSyncJournalEntry) {
        entriesByRepo[entry.repoID] = entry
        persist()
    }

    /// Forgets entries for repositories that no longer exist. The journal holds
    /// repository names, so it must not outlive the repositories it describes.
    func prune(keeping repoIDs: Set<UUID>) {
        let remaining = entriesByRepo.filter { repoIDs.contains($0.key) }
        guard remaining.count != entriesByRepo.count else { return }
        entriesByRepo = remaining
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entriesByRepo) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
@Observable
final class VaultBridgeSyncCoordinator {
    /// A clean vault still checks its working tree whenever VaultBridge becomes
    /// active, but an authenticated fetch is unnecessary on every app switch.
    /// Manual sync always bypasses this interval.
    static let automaticRemoteCheckInterval: TimeInterval = 10 * 60

    private(set) var statusByRepo: [UUID: VaultBridgeSyncStatus] = [:]
    private(set) var isSyncingAll = false
    private var lastForegroundSync: Date?
    private var runIDByRepo: [UUID: UUID] = [:]
    private var runModeByRepo: [UUID: String] = [:]
    private var checkpointSHAByRepo: [UUID: String] = [:]

    func status(for repoID: UUID) -> VaultBridgeSyncStatus {
        statusByRepo[repoID] ?? VaultBridgeSyncStatus()
    }

    @discardableResult
    func syncAll(using state: AppState, automatic: Bool = false) async -> Bool {
        if !automatic {
            return await VaultBridgeBackgroundExecution.shared.run(title: "Synchronizing VaultBridge") { [weak self, weak state] in
                guard let self, let state else { return false }
                return await self.performSyncAll(using: state, automatic: false)
            }
        }
        return await VaultBridgeBackgroundExecution.shared.runAutomatic(title: "Automatic VaultBridge sync") { [weak self, weak state] in
            guard let self, let state else { return false }
            return await self.performSyncAll(using: state, automatic: true)
        }
    }

    private func performSyncAll(using state: AppState, automatic: Bool) async -> Bool {
        guard !isSyncingAll, !state.isSyncing else { return false }
        isSyncingAll = true
        defer { isSyncingAll = false }

        let keepIDs = Set(state.repos.map(\.id))
        statusByRepo = statusByRepo.filter { keepIDs.contains($0.key) }
        await VaultBridgeSyncJournal.shared.prune(keeping: keepIDs)

        let repos = state.repos.filter { $0.isCloned && (!automatic || $0.autoSyncEnabled) }
        for repo in repos {
            if Task.isCancelled { break }
            await syncRepository(repoID: repo.id, using: state, automatic: automatic)
        }
        return true
    }

    func syncOnForeground(using state: AppState) async {
        if let lastForegroundSync, Date().timeIntervalSince(lastForegroundSync) < 45 { return }
        // Stamp before awaiting so a second foreground event cannot double-enter,
        // but give the window back if the sync was skipped (e.g. a manual
        // operation was in flight) so the next foreground retries.
        let previousForegroundSync = lastForegroundSync
        lastForegroundSync = Date()
        let ran = await syncAll(using: state, automatic: true)
        if !ran {
            lastForegroundSync = previousForegroundSync
        }
    }

    func sync(repoID: UUID, using state: AppState) async {
        guard let repo = state.repo(id: repoID) else { return }
        _ = await VaultBridgeBackgroundExecution.shared.run(title: "Synchronizing \(repo.displayName)") { [weak self, weak state] in
            guard let self, let state, !self.isSyncingAll, !state.isSyncing else { return false }
            await self.syncRepository(repoID: repoID, using: state, automatic: false)
            return self.status(for: repoID).phase == .complete
        }
    }

    private func syncRepository(repoID: UUID, using state: AppState, automatic: Bool) async {
        guard !status(for: repoID).isRunning,
              let repo = state.repo(id: repoID),
              repo.isCloned else { return }

        runIDByRepo[repoID] = UUID()
        runModeByRepo[repoID] = automatic ? "automatic" : "manual"
        checkpointSHAByRepo[repoID] = repo.gitState.commitSHA

        // Demo repositories have no working copy on disk; report success
        // without touching Git so App Review sees a working dashboard.
        if state.isDemoMode {
            await update(repo: repo, phase: .complete, message: "Up to date")
            return
        }

        if automatic && ProcessInfo.processInfo.isLowPowerModeEnabled {
            await update(repo: repo, phase: .idle, message: "Automatic sync paused in Low Power Mode")
            return
        }

        func stopForAttention(_ message: String) async {
            await update(repo: repo, phase: .attention, message: message)
            if automatic, repo.syncNotificationsEnabled {
                await VaultBridgeLocalNotifications.post(repo: repo, needsAttention: true)
            }
        }

        await update(repo: repo, phase: .inspecting, message: "Checking this phone")
        do {
            var info = try await state.inspectRepositoryForVaultBridge(repoID: repoID)
            if !info.commitSHA.isEmpty {
                checkpointSHAByRepo[repoID] = info.commitSHA
            }
            let now = Date()
            let lastRemoteCheck = repo.gitState.lastSyncDate
            let remoteCheckIsFresh = lastRemoteCheck != .distantPast
                && now.timeIntervalSince(lastRemoteCheck) < Self.automaticRemoteCheckInterval

            // This is the common path after a successful sync: one read-only
            // working-tree inspection, no full stage, no network, no push, and
            // no notification. A manual tap still forces the complete check.
            if automatic,
               info.changeCount == 0,
               info.syncState == .upToDate,
               remoteCheckIsFresh,
               state.shelteredEditsByRepo[repoID] == nil {
                await update(repo: repo, phase: .complete, message: "Up to date")
                return
            }

            // An interrupted combine whose choices have all been made only
            // needs its commit. Finish it here so the user never has to learn
            // what "complete merge" means.
            await state.loadConflictSession(repoID: repoID)
            var session = state.conflictSessionByRepo[repoID] ?? .none
            if session.kind == .merge, !session.hasConflicts {
                await update(repo: repo, phase: .reconciling, message: "Finishing the combine")
                await state.completeMerge(
                    repoID: repoID,
                    message: "Combine phone and server changes",
                    presentsErrors: !automatic
                )
                await state.loadConflictSession(repoID: repoID)
                session = state.conflictSessionByRepo[repoID] ?? .none
                info = try await state.inspectRepositoryForVaultBridge(repoID: repoID)
            }
            if session.isActive {
                await stopForAttention(Self.attentionMessage(for: session))
                return
            }

            // Edits sheltered by an earlier combine or replacement go back
            // first, so this save includes them.
            if state.shelteredEditsByRepo[repoID] != nil {
                await update(repo: repo, phase: .reconciling, message: "Putting sheltered edits back")
                let restored = await state.restoreShelteredEdits(repoID: repoID, presentsErrors: !automatic)
                info = try await state.inspectRepositoryForVaultBridge(repoID: repoID)
                if !restored {
                    await state.loadConflictSession(repoID: repoID)
                    let message = state.pullOutcomeByRepo[repoID]?.message
                        ?? "Sheltered edits could not be put back yet."
                    await stopForAttention(message)
                    return
                }
            }

            var committed = false
            var checkpointPass = 0
            var lastPassCommitted = true
            var entryStatesByPass: [Set<String>] = [Self.entryStateSet(info.statusEntries)]
            while info.changeCount > 0 && checkpointPass < 3 {
                checkpointPass += 1
                await update(
                    repo: repo,
                    phase: .committing,
                    message: checkpointPass == 1 ? "Saving on this phone" : "Saving on this phone (pass \(checkpointPass))"
                )
                let didCommit = try await state.commitAllLocallyForVaultBridge(
                    repoID: repoID,
                    message: Self.automaticCommitMessage(),
                    statusEntries: info.statusEntries,
                    refreshStatus: false
                )
                committed = didCommit || committed
                lastPassCommitted = didCommit
                if didCommit {
                    if let latestSHA = state.repo(id: repoID)?.gitState.commitSHA, !latestSHA.isEmpty {
                        checkpointSHAByRepo[repoID] = latestSHA
                    }
                    // File Provider and editors can finish a coordinated write
                    // just after the index commit. Give that write a brief
                    // settling window before deciding another checkpoint is
                    // required; otherwise all retries can run in under a
                    // second against a still-moving snapshot.
                    try await Task.sleep(for: .milliseconds(650))
                }
                info = try await state.inspectRepositoryForVaultBridge(repoID: repoID)
                entryStatesByPass.append(Self.entryStateSet(info.statusEntries))
                if entryStatesByPass.count >= 3,
                   entryStatesByPass[entryStatesByPass.count - 1] == entryStatesByPass[entryStatesByPass.count - 3],
                   entryStatesByPass[entryStatesByPass.count - 1] != entryStatesByPass[entryStatesByPass.count - 2] {
                    break
                }
                // Nothing was committable from this snapshot. Another pass
                // would only stage the same entries again.
                if !didCommit { break }
            }
            var stillChangingCount = 0
            if info.changeCount > 0 {
                let count = info.changeCount
                // Each pass commits, yet the set of reported files alternates
                // between two states. Git is reporting the same file
                // inconsistently; more passes would only add commits.
                let flipping = entryStatesByPass.count >= 3
                    && entryStatesByPass[entryStatesByPass.count - 1] == entryStatesByPass[entryStatesByPass.count - 3]
                    && entryStatesByPass[entryStatesByPass.count - 1] != entryStatesByPass[entryStatesByPass.count - 2]
                if flipping {
                    DebugLogger.shared.warning(
                        "vaultbridge",
                        "Checkpoint entries flip between two states",
                        detail: "passes=\(checkpointPass) counts=\(entryStatesByPass.map(\.count))"
                    )
                    await stopForAttention(count == 1
                        ? "Git reports 1 file inconsistently. VaultBridge stopped before creating another duplicate save. Open Git Tools for details."
                        : "Git reports \(count) files inconsistently. VaultBridge stopped before creating another duplicate save. Open Git Tools for details.")
                    return
                }
                if !lastPassCommitted {
                    await stopForAttention(count == 1
                        ? "1 file could not be saved on this phone. Open Git Tools to see it."
                        : "\(count) files could not be saved on this phone. Open Git Tools to see them.")
                    return
                }
                // Every pass saved something and files are still moving. What
                // is saved is worth uploading now; the rest is picked up by
                // the next sync instead of holding everything hostage.
                stillChangingCount = count
            }
            if committed {
                await update(repo: repo, phase: .committing, message: "Saved on this phone")
            }

            await update(repo: repo, phase: .fetching, message: "Checking the server")
            guard await state.pullWithMerge(
                repoID: repoID,
                presentsErrors: !automatic,
                refreshStatus: false
            ) else {
                let outcome = state.pullOutcomeByRepo[repoID]
                let needsAttention = outcome?.kind == .mergeConflicts
                    || outcome?.kind == .blockedByLocalChanges
                    || outcome?.kind == .diverged
                let message = outcome?.message ?? "The server could not be checked"
                if needsAttention {
                    await stopForAttention(message)
                } else if outcome?.kind == .cancelled {
                    await update(repo: repo, phase: .idle, message: message)
                } else {
                    await update(repo: repo, phase: .failed, message: message)
                }
                return
            }

            await update(repo: repo, phase: .comparing, message: "Comparing phone and server")
            state.markVaultBridgeRemoteCheckSucceeded(repoID: repoID)
            let pullKind = state.pullOutcomeByRepo[repoID]?.kind
            if pullKind == .merged || pullKind == .fastForwarded {
                await update(repo: repo, phase: .reconciling, message: "Bringing server changes onto this phone")
            }
            let localHasCommits = !(state.repo(id: repoID)?.gitState.commitSHA ?? "").isEmpty
            let shouldPush: Bool
            switch pullKind {
            case .merged:
                shouldPush = true
            case .remoteBranchMissing:
                shouldPush = localHasCommits
            default:
                shouldPush = committed
                    || info.syncState == .ahead
                    || state.syncStateByRepo[repoID] == .ahead
            }
            if shouldPush {
                await update(repo: repo, phase: .pushing, message: "Uploading to the server")
                guard await state.pushCurrentBranch(
                    repoID: repoID,
                    presentsErrors: !automatic,
                    refreshStatus: false,
                    preflightFetch: false
                ) else {
                    // pushErrorByRepo is per-repository and cleared when each
                    // push starts, so this is the typed failure for THIS repo.
                    let pushError = state.pushErrorByRepo[repoID]
                    let outcome = state.pullOutcomeByRepo[repoID]
                    let message = pushError?.message ?? outcome?.message ?? "Upload could not be completed"
                    if pushError?.isLFSRepairEligible == true || outcome?.kind == .diverged {
                        await stopForAttention(message)
                    } else if outcome?.kind == .cancelled {
                        await update(repo: repo, phase: .idle, message: message)
                    } else {
                        await update(repo: repo, phase: .failed, message: message)
                    }
                    return
                }
            }

            let movedChanges = shouldPush || pullKind == .fastForwarded || pullKind == .merged
            let message: String
            if shouldPush {
                if pullKind == .merged {
                    message = "Combined and uploaded"
                } else if committed {
                    message = "Saved and uploaded"
                } else {
                    message = "Uploaded"
                }
            } else if pullKind == .fastForwarded {
                message = "Server notes brought onto this phone"
            } else {
                message = "Up to date"
            }
            await update(repo: repo, phase: .verifying, message: "Verifying phone and server")
            let suffix = stillChangingCount == 0 ? "" : (stillChangingCount == 1
                ? ". 1 note is still changing and will be saved next time"
                : ". \(stillChangingCount) notes are still changing and will be saved next time")
            await update(repo: repo, phase: .complete, message: message + suffix)
            if automatic, movedChanges, repo.syncNotificationsEnabled {
                await VaultBridgeLocalNotifications.post(repo: repo, needsAttention: false)
            }
        } catch let error as LocalGitError {
            if case .conflictSessionInProgress = error {
                await stopForAttention(error.localizedDescription)
            } else {
                presentSyncError(error.localizedDescription, using: state, automatic: automatic)
                await update(repo: repo, phase: .failed, message: error.localizedDescription)
            }
        } catch is CancellationError {
            // An abandoned pull-to-refresh or torn-down task is not a failure;
            // return the card to idle without raising an alert.
            await update(repo: repo, phase: .idle, message: "Sync cancelled")
        } catch {
            presentSyncError(error.localizedDescription, using: state, automatic: automatic)
            await update(repo: repo, phase: .failed, message: error.localizedDescription)
        }
    }

    static func attentionMessage(for session: ConflictSession) -> String {
        let count = session.unmergedPaths.count
        switch session.kind {
        case .rebase:
            return count > 0
                ? "A rebase is waiting for your choice on \(count) note\(count == 1 ? "" : "s"). Open Git Tools."
                : "A rebase is waiting to continue. Open Git Tools."
        default:
            return AppState.conflictChoiceMessage(count: count)
        }
    }

    /// Automatic runs must never raise modal alerts — an offline device would
    /// otherwise present a Git error on every foreground. The phase, journal,
    /// and debug log still carry the failure.
    private func presentSyncError(_ message: String, using state: AppState, automatic: Bool) {
        if automatic {
            DebugLogger.shared.error("vaultbridge", message)
        } else {
            state.showError(message: message, category: "vaultbridge")
        }
    }

    private func update(repo: RepoConfig, phase: VaultBridgeSyncPhase, message: String) async {
        let now = Date()
        statusByRepo[repo.id] = VaultBridgeSyncStatus(phase: phase, message: message, date: now)
        await VaultBridgeSyncJournal.shared.record(.init(
            repoID: repo.id,
            repoName: repo.displayName,
            phase: phase,
            message: message,
            date: now,
            runID: runIDByRepo[repo.id],
            mode: runModeByRepo[repo.id],
            progress: progress(for: phase),
            checkpointSHA: checkpointSHAByRepo[repo.id].flatMap { $0.isEmpty ? nil : $0 }
        ))
    }

    private func progress(for phase: VaultBridgeSyncPhase) -> Int {
        switch phase {
        case .idle: 0
        case .inspecting: 1
        case .committing: 2
        case .fetching, .pulling: 3
        case .comparing: 4
        case .reconciling: 5
        case .pushing: 6
        case .verifying, .complete: 7
        case .attention, .failed: 0
        }
    }

    private static func automaticCommitMessage(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "VaultBridge automatic sync \(formatter.string(from: now))"
    }

    /// A path alone cannot reveal the add/delete two-cycle produced by a stale
    /// index spelling. Include both status sides so the safety stop recognizes
    /// that oscillation before another redundant checkpoint is uploaded.
    private static func entryStateSet(_ entries: [GitStatusEntry]) -> Set<String> {
        Set(entries.map {
            "\($0.path)|i=\($0.indexStatus?.rawValue ?? "-")|w=\($0.workTreeStatus?.rawValue ?? "-")|old=\($0.oldPath ?? "-")"
        })
    }
}

extension AppState {
    /// Performs the single status pass that drives the optimized foreground
    /// decision and publishes it directly, avoiding a second detached scan.
    func inspectRepositoryForVaultBridge(repoID: UUID) async throws -> LocalRepoInfo {
        guard repo(id: repoID)?.isCloned == true else { throw LocalGitError.notCloned }
        markRepositoryInspectionStarted(repoID: repoID)
        let serialized = try serializedRepository(repoID: repoID)
        let info = try await serialized.withLease { repository in
            guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
            return try await repository.repoInfo()
        }
        if let index = repoIndex(id: repoID) {
            repos[index].gitState.branch = info.branch
            repos[index].gitState.commitSHA = info.commitSHA
            if !info.remoteCommitSHA.isEmpty {
                repos[index].gitState.remoteCommitSHA = info.remoteCommitSHA
            }
        }
        changeCounts[repoID] = info.changeCount
        statusEntriesByRepo[repoID] = info.statusEntries
        syncStateByRepo[repoID] = info.syncState
        markRepositoryInspectionCompleted(repoID: repoID)
        return info
    }

    func markVaultBridgeRemoteCheckSucceeded(repoID: UUID) {
        guard let index = repoIndex(id: repoID) else { return }
        repos[index].gitState.lastSyncDate = Date()
        repos[index].gitState.lastRemoteCheckDate = Date()
        saveRepos()
    }

    /// Equivalent to `git add -A` followed by a local commit. Deletions are
    /// included, and no network operation is performed.
    @discardableResult
    func commitAllLocallyForVaultBridge(
        repoID: UUID,
        message: String,
        statusEntries capturedEntries: [GitStatusEntry]? = nil,
        refreshStatus: Bool = true
    ) async throws -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { throw LocalGitError.notCloned }
        let authorName = repo.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorEmail = repo.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorName.isEmpty, !authorEmail.isEmpty else {
            throw LocalGitError.invalidAuthorIdentity("Set a Git author name and email for \(repo.displayName) before committing.")
        }

        let serialized = try serializedRepository(repoID: repoID)
        do {
            let sha = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                // An interrupted merge/rebase leaves conflict entries in the
                // index. Staging everything here would silently resolve them
                // with whatever is in the working tree (conflict markers
                // included) and commit on the in-progress state. Stop instead;
                // the conflict UI owns this repository until it is finished
                // or aborted.
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }
                let entries: [GitStatusEntry]
                if let capturedEntries {
                    entries = capturedEntries
                } else {
                    entries = try await repository.repoInfo().statusEntries
                }
                guard !entries.isEmpty else { throw LocalGitError.noChanges }

                let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "VaultBridge local commit"
                    : message

                // Apply the Git LFS auto-tracking policy (including
                // .gitattributes) before every automatic commit. Raw staging
                // here once let multi-gigabyte media land in history as
                // ordinary blobs that the push validator then rejected.
                try await repository.stageChanges(entries, lfsAutoTrack: true)
                do {
                    return try await repository.commitLocal(
                        message: commitMessage,
                        authorName: authorName,
                        authorEmail: authorEmail
                    )
                } catch LocalGitError.noChanges {
                    // Status listed entries but staging them one path at a
                    // time changed nothing. The index is holding something the
                    // per-path API cannot address: a stale duplicate entry, a
                    // spelling the filesystem cannot produce, or a stale Git
                    // LFS pointer. Rebuilding the index from the last commit
                    // plus the files on disk discards all of that, so escalate
                    // to it once before reporting that the files cannot be
                    // saved. This is the same operation as expert Force Save.
                    try await repository.rebuildIndexFromWorkingTree(lfsAutoTrack: true)
                    return try await repository.commitLocal(
                        message: commitMessage,
                        authorName: authorName,
                        authorEmail: authorEmail
                    )
                }
            }
            markRepositoryMutated(repoID: repoID)
            if let index = repoIndex(id: repoID) {
                repos[index].gitState.commitSHA = sha
                repos[index].gitState.localCheckpointDate = Date()
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            if refreshStatus { detectChanges(repoID: repoID) }
            return true
        } catch LocalGitError.noChanges {
            return false
        }
    }

    func commitAllLocallyForVaultBridgeWithUI(repoID: UUID, message: String) async -> Bool {
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = "Staging all changes and committing locally…"
        defer {
            isSyncing = false
            syncingRepoID = nil
        }
        do {
            let committed = try await commitAllLocallyForVaultBridge(repoID: repoID, message: message)
            let shortSHA = repo(id: repoID).map { String($0.gitState.commitSHA.prefix(7)) } ?? ""
            syncProgress = committed
                ? "Saved on this iPhone as \(shortSHA). Not uploaded."
                : "Already saved on this iPhone at \(shortSHA). Nothing new to save."
            pullOutcomeByRepo[repoID] = PullOutcomeState(
                kind: .saved,
                message: syncProgress,
                date: Date()
            )
            return true
        } catch is CancellationError {
            syncProgress = "Save cancelled"
            pullOutcomeByRepo[repoID] = PullOutcomeState(kind: .cancelled, message: syncProgress, date: Date())
            return false
        } catch {
            showError(message: error.localizedDescription, category: "commit")
            return false
        }
    }
}
