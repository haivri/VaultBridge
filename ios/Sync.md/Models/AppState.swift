import Foundation
import SwiftUI

struct GitHubAccount: Codable, Identifiable, Equatable {
    var id: String { login.lowercased() }

    let login: String
    var displayName: String
    var avatarURL: String
    var email: String
}

struct LFSAutoTrackingConfirmationRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case stageFile(path: String, oldPath: String?)
        case stageAll
    }

    let id = UUID()
    let repoID: UUID
    let action: Action
    let candidates: [GitLFSAutoTrackingCandidate]

    var message: String {
        let listed = candidates.prefix(4).map { candidate in
            "• \(candidate.path) (\(ByteCountFormatter.string(fromByteCount: candidate.sizeBytes, countStyle: .file)))"
        }.joined(separator: "\n")
        let remaining = candidates.count > 4 ? "\n• +\(candidates.count - 4) more" : ""
        return String(localized: "These files look binary or large and are safer in Git LFS:\n\n\(listed)\(remaining)\n\nUse Git LFS? This will update and stage .gitattributes.")
    }
}

struct SSHHostKeyTrustRequest: Identifiable, Equatable {
    enum Operation: Equatable {
        case clone
        case pull
        case pushCurrentBranch
        case pushCommit(message: String)
    }

    let id = UUID()
    let repoID: UUID
    let operation: Operation
    let trustError: GitLFSSSHHostKeyTrustError

    var title: String {
        switch trustError {
        case .unknownHostKey:
            return String(localized: "Trust SSH Host?")
        case .changedHostKey:
            return String(localized: "SSH Host Key Changed")
        }
    }

    var confirmButtonTitle: String {
        switch trustError {
        case .unknownHostKey:
            return String(localized: "Trust Host")
        case .changedHostKey:
            return String(localized: "Trust New Key")
        }
    }

    var message: String {
        switch trustError {
        case .unknownHostKey(let host, let port, let fingerprint):
            let portString = String(port)
            return String(localized: "\(host):\(portString) presented this SSH host key:\n\n\(fingerprint)\n\nOnly trust it if this fingerprint matches your Forgejo/Git server.")
        case .changedHostKey(let host, let port, let expectedFingerprint, let actualFingerprint):
            let portString = String(port)
            return String(localized: "\(host):\(portString) presented a different SSH host key.\n\nPreviously trusted:\n\(expectedFingerprint)\n\nNew key:\n\(actualFingerprint)\n\nDo not trust the new key unless you intentionally rotated the server's SSH host key.")
        }
    }

    var host: String {
        switch trustError {
        case .unknownHostKey(let host, _, _), .changedHostKey(let host, _, _, _):
            return host
        }
    }

    var port: Int {
        switch trustError {
        case .unknownHostKey(_, let port, _), .changedHostKey(_, let port, _, _):
            return port
        }
    }

    var fingerprintToTrust: String {
        switch trustError {
        case .unknownHostKey(_, _, let fingerprint):
            return fingerprint
        case .changedHostKey(_, _, _, let actualFingerprint):
            return actualFingerprint
        }
    }
}

private struct CommitMergeExecution: Sendable {
    let committedSHA: String?
    let mergeResult: MergeResult?
    let mergeConflicted: Bool
    let mergeErrorMessage: String?
    let pushErrorMessage: String?
}

private struct MergePushExecution: Sendable {
    let result: MergeResult
    let pushErrorMessage: String?
}

private struct FinalizeMergePushExecution: Sendable {
    let result: MergeFinalizeResult
    let pushErrorMessage: String?
}

private struct RebasePullExecution: Sendable {
    let plan: PullPlan
    let result: LocalPullResult?
}

private struct VaultBridgeSafeMergeExecution: Sendable {
    let committedSHA: String?
    let remoteCommitSHA: String
    let mergeResult: MergeResult?
    let mergeConflicted: Bool
    let shelvedEdits: Bool
    let shelfRestored: Bool
    let shelfConflicted: Bool
    let shelfMessage: String?
}

private struct MergePullExecution: Sendable {
    let plan: PullPlan
    let fastForward: LocalPullResult?
    let merge: MergeResult?
}

private enum PushExecution: Sendable {
    case pushed(LocalRepoInfo?)
    case serverMoved(PullPlan)
}

private struct ProtectedRestoreExecution: Sendable {
    let restoredSHA: String
    let snapshotOfPreviousState: GitRecoverySnapshot
    let previousStashReapplied: Bool
}

/// Thrown when an operation failed after the user's live edits had already
/// been moved into a stash. The caller records the shelter so the edits stay
/// visible and are put back automatically on the next sync.
private struct VaultBridgeStrandedShelfError: Error, Sendable {
    let underlying: any Error
    let stashMessage: String
}

// MARK: - App State

@MainActor
@Observable
final class AppState {

    // MARK: - Repositories

    var repos: [RepoConfig] = []
    var changeCounts: [UUID: Int] = [:]
    var statusEntriesByRepo: [UUID: [GitStatusEntry]] = [:]
    var syncStateByRepo: [UUID: RepoSyncState] = [:]
    var pullOutcomeByRepo: [UUID: PullOutcomeState] = [:]
    var pushErrorByRepo: [UUID: PushErrorState] = [:]
    var diffByRepo: [UUID: UnifiedDiffResult] = [:]
    var branchesByRepo: [UUID: BranchInventory] = [:]
    var conflictSessionByRepo: [UUID: ConflictSession] = [:]
    var commitHistoryByRepo: [UUID: [GitCommitSummary]] = [:]
    var commitHistoryHasMoreByRepo: [UUID: Bool] = [:]
    var commitDetailByRepo: [UUID: [String: GitCommitDetail]] = [:]
    var stashesByRepo: [UUID: [GitStashEntry]] = [:]
    var tagsByRepo: [UUID: [GitTag]] = [:]
    var recoveryByRepo: [UUID: GitRecoverySnapshot] = [:]
    /// Edits moved into a stash by a combine or replacement that have not been
    /// put back yet. Shown on the vault screen and re-applied by the next sync.
    var shelteredEditsByRepo: [UUID: VaultBridgeShelteredEdits] = [:]

    // MARK: - Sync State

    var isSyncing: Bool = false
    var syncingRepoID: UUID? = nil
    var syncProgress: String = ""

    // MARK: - OAuth / Auth

    var isSignedIn: Bool = false
    var gitHubUsername: String = ""
    var gitHubDisplayName: String = ""
    var gitHubAvatarURL: String = ""
    var defaultAuthorName: String = ""
    var defaultAuthorEmail: String = ""
    var gitHubRepos: [GitHubRepo] = []
    var isLoadingRepos: Bool = false
    var gitHubAccounts: [GitHubAccount] = []
    var activeGitHubAccountLogin: String = ""

    // MARK: - Callback State (x-callback-url from Obsidian plugin)

    /// When set, the UI programmatically navigates to this repo's VaultView.
    var callbackNavigateToRepoID: UUID? = nil

    /// Result from a completed callback operation — shown briefly before redirecting.
    var callbackResult: CallbackResultState? = nil

    // MARK: - Default Save Location

    var defaultSaveLocationBookmarkData: Data? = nil
    var resolvedDefaultSaveURL: URL? = nil
    private var defaultSaveAccessingScope: Bool = false

    /// Whether onboarding (including the save-location step) has been completed.
    var hasCompletedOnboarding: Bool = false

    /// Whether the user has seen the feature onboarding slides.
    var hasSeenOnboarding: Bool = false

    // MARK: - Demo Mode

    var isDemoMode: Bool = false

    // MARK: - Review Prompt

    /// Set to `true` after the user's first successful clone, so the UI can trigger a review request.
    var shouldRequestReview: Bool = false

    // MARK: - Errors & Confirmations

    var lastError: String? = nil
    var showError: Bool = false
    var pendingLFSAutoTrackingConfirmation: LFSAutoTrackingConfirmationRequest? = nil
    var pendingSSHHostKeyTrustRequest: SSHHostKeyTrustRequest? = nil

    // MARK: - Security-Scoped URLs (runtime only)

    private var resolvedCustomURLs: [UUID: URL] = [:]
    private var accessingSecurityScope: Set<UUID> = []

    // MARK: - Background Status Refresh

    private var changeDetectionInFlight: Set<UUID> = []
    private var pendingChangeDetection: Set<UUID> = []
    private var lastChangeDetectionStartedAt: [UUID: Date] = [:]
    private var lastRepositoryInspectionCompletedAt: [UUID: Date] = [:]
    private var repoMutationGeneration: [UUID: Int] = [:]
    private var didScheduleInitialChangeDetection = false

    // MARK: - PAT / GitHub Accounts

    var pat: String {
        get {
            if let token = gitHubToken(for: activeGitHubAccountLogin), !token.isEmpty {
                return token
            }
            return KeychainService.load(key: "github_pat") ?? ""
        }
        set {
            if newValue.isEmpty {
                if !activeGitHubAccountLogin.isEmpty {
                    KeychainService.delete(key: Self.gitHubTokenKey(for: activeGitHubAccountLogin))
                }
                KeychainService.delete(key: "github_pat")
            } else if !activeGitHubAccountLogin.isEmpty {
                KeychainService.save(key: Self.gitHubTokenKey(for: activeGitHubAccountLogin), value: newValue)
            } else {
                KeychainService.save(key: "github_pat", value: newValue)
            }
        }
    }

    var activeGitHubAccount: GitHubAccount? {
        gitHubAccounts.first { $0.login.caseInsensitiveCompare(activeGitHubAccountLogin) == .orderedSame }
    }

    var visibleRepos: [RepoConfig] {
        repos.filter { shouldShowRepoForActiveAccount($0) }
    }

    private static func gitHubTokenKey(for login: String) -> String {
        "github_pat_\(login.lowercased())"
    }

    func gitHubToken(for login: String?) -> String? {
        guard let login = login?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty else { return nil }
        return KeychainService.load(key: Self.gitHubTokenKey(for: login))
    }

    private func shouldShowRepoForActiveAccount(_ repo: RepoConfig) -> Bool {
        if isDemoMode { return true }
        if let ownerLogin = repo.gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines), !ownerLogin.isEmpty {
            return isSignedIn && ownerLogin.caseInsensitiveCompare(activeGitHubAccountLogin) == .orderedSame
        }
        if repo.authMethod == .gitHubPAT, GitRemoteURL.parse(repo.repoURL)?.isGitHub == true {
            return isSignedIn
        }
        return true
    }

    // MARK: - Per-Repo Remote Credentials

    private static func repoCredentialKey(_ repoID: UUID, _ suffix: String) -> String {
        "repo_\(repoID.uuidString)_\(suffix)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func saveRemoteCredentials(_ credentials: GitRemoteCredentials, for repoID: UUID) {
        clearRemoteCredentials(for: repoID)

        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            KeychainService.save(key: Self.repoCredentialKey(repoID, "username"), value: username)
        }
        if !credentials.password.isEmpty {
            KeychainService.save(key: Self.repoCredentialKey(repoID, "password"), value: credentials.password)
        }
        if !credentials.privateKey.isEmpty {
            KeychainService.save(key: Self.repoCredentialKey(repoID, "ssh_private_key"), value: credentials.privateKey)
        }
        if !credentials.publicKey.isEmpty {
            KeychainService.save(key: Self.repoCredentialKey(repoID, "ssh_public_key"), value: credentials.publicKey)
        }
        if !credentials.passphrase.isEmpty {
            KeychainService.save(key: Self.repoCredentialKey(repoID, "ssh_passphrase"), value: credentials.passphrase)
        }
    }

    func clearRemoteCredentials(for repoID: UUID) {
        KeychainService.delete(key: Self.repoCredentialKey(repoID, "username"))
        KeychainService.delete(key: Self.repoCredentialKey(repoID, "password"))
        KeychainService.delete(key: Self.repoCredentialKey(repoID, "ssh_private_key"))
        KeychainService.delete(key: Self.repoCredentialKey(repoID, "ssh_public_key"))
        KeychainService.delete(key: Self.repoCredentialKey(repoID, "ssh_passphrase"))
    }

    func remoteCredentials(for repo: RepoConfig) -> GitRemoteCredentials {
        switch repo.authMethod {
        case .gitHubPAT:
            let token = gitHubToken(for: repo.gitHubAccountLogin) ?? pat
            return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .gitHubPAT(token)
        case .none:
            return .none
        case .httpsToken:
            let username = Self.firstNonEmpty(
                KeychainService.load(key: Self.repoCredentialKey(repo.id, "username")),
                repo.authUsername,
                GitRemoteURL.parse(repo.repoURL)?.username
            ) ?? ""
            let password = KeychainService.load(key: Self.repoCredentialKey(repo.id, "password")) ?? ""
            return .httpsToken(username: username, password: password)
        case .sshKey:
            let username = Self.firstNonEmpty(
                KeychainService.load(key: Self.repoCredentialKey(repo.id, "username")),
                repo.authUsername,
                GitRemoteURL.parse(repo.repoURL)?.username
            ) ?? "git"
            return .sshKey(
                username: username,
                privateKey: KeychainService.load(key: Self.repoCredentialKey(repo.id, "ssh_private_key")) ?? "",
                publicKey: KeychainService.load(key: Self.repoCredentialKey(repo.id, "ssh_public_key")) ?? "",
                passphrase: KeychainService.load(key: Self.repoCredentialKey(repo.id, "ssh_passphrase")) ?? ""
            )
        }
    }

    func authPayload(for repo: RepoConfig) -> String {
        remoteCredentials(for: repo).transportPayload
    }

    // MARK: - Dependencies

    private let gitRepositoryFactory: (URL) -> any GitRepositoryProtocol
    private let sshHostKeyTrustStore: any GitLFSSSHHostKeyTrustStore
    private let repoPersistenceStore: RepoPersistenceStore
    private let persistedReposURL: URL
    private var persistedRepoSnapshot: [UUID: RepoConfig] = [:]
    var assistConfigurationChangeHandler: (@MainActor @Sendable () -> Void)?
    var assistRepositoryRemovalHandler: (@MainActor @Sendable (RepoConfig) -> Void)?

    // MARK: - Init

    init(
        gitRepositoryFactory: @escaping (URL) -> any GitRepositoryProtocol = { LocalGitService(localURL: $0) },
        sshHostKeyTrustStore: any GitLFSSSHHostKeyTrustStore = GitLFSSSHHostKeyFileTrustStore.default,
        repoPersistenceStore: RepoPersistenceStore = .shared,
        reposFileURL: URL? = nil,
        loadPersistedState: Bool = true
    ) {
        self.gitRepositoryFactory = { url in
            SerializedGitRepository(base: gitRepositoryFactory(url), localURL: url)
        }
        self.sshHostKeyTrustStore = sshHostKeyTrustStore
        self.repoPersistenceStore = repoPersistenceStore
        self.persistedReposURL = reposFileURL ?? Self.reposFileURL
        if loadPersistedState {
            loadState()
            migrateKnownGitCredentialAccessibilityIfNeeded()
        }
    }

    // MARK: - Persistence

    nonisolated static var persistedReposFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("SyncMD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("repos.json")
    }

    nonisolated private static var reposFileURL: URL {
        persistedReposFileURL
    }

    nonisolated static func loadPersistedRepos() -> [RepoConfig] {
        RepoPersistenceStore.shared.load(from: persistedReposFileURL)
    }

    private func loadState() {
        let defaults = UserDefaults.standard
        gitHubUsername = defaults.string(forKey: "gitHubUsername") ?? ""
        gitHubDisplayName = defaults.string(forKey: "gitHubDisplayName") ?? ""
        gitHubAvatarURL = defaults.string(forKey: "gitHubAvatarURL") ?? ""
        defaultAuthorName = defaults.string(forKey: "authorName") ?? ""
        defaultAuthorEmail = defaults.string(forKey: "authorEmail") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        hasSeenOnboarding = defaults.bool(forKey: "hasSeenOnboarding")

        if let recoveryData = defaults.data(forKey: "vaultbridge.protected-recoveries.v1"),
           let recoveries = try? JSONDecoder().decode([UUID: GitRecoverySnapshot].self, from: recoveryData) {
            recoveryByRepo = recoveries
        }
        if let shelteredData = defaults.data(forKey: Self.shelteredEditsDefaultsKey),
           let sheltered = try? JSONDecoder().decode([UUID: VaultBridgeShelteredEdits].self, from: shelteredData) {
            shelteredEditsByRepo = sheltered
        }

        if let accountData = defaults.data(forKey: "gitHubAccounts"),
           let decodedAccounts = try? JSONDecoder().decode([GitHubAccount].self, from: accountData) {
            gitHubAccounts = decodedAccounts
        }
        activeGitHubAccountLogin = defaults.string(forKey: "activeGitHubAccountLogin") ?? ""
        migrateLegacyGitHubAccountIfNeeded()
        restoreActiveGitHubAccount()

        // Load default save location bookmark
        defaultSaveLocationBookmarkData = defaults.data(forKey: "defaultSaveLocationBookmark")
        resolveDefaultSaveBookmark()

        // Try to load multi-repo state
        let persistedRepos: [RepoConfig]
        do {
            persistedRepos = try repoPersistenceStore.loadStrict(from: persistedReposURL)
        } catch {
            persistedRepos = []
            DebugLogger.shared.error("persistence", "Could not load repository settings", detail: error.localizedDescription)
            lastError = error.localizedDescription
            showError = true
        }
        if !persistedRepos.isEmpty || FileManager.default.fileExists(atPath: persistedReposURL.path) {
            repos = persistedRepos
            persistedRepoSnapshot = Dictionary(uniqueKeysWithValues: persistedRepos.map { ($0.id, $0) })
        } else {
            // Migration from single-repo state
            migrateFromLegacy()
        }

        migrateRepoAccountOwnershipIfNeeded()

        // Resolve custom vault bookmarks
        for repo in repos {
            resolveVaultBookmark(for: repo.id)
        }

        // Validate that cloned repos still exist on disk
        validateClonedRepos()

        // Do not scan Git status synchronously during app construction. Large
        // vaults (especially hydrated Git LFS files) can make launch appear as
        // a black screen or trigger iOS watchdog kills. The first refresh is
        // scheduled after the initial UI frame in ContentView.onAppear.
    }

    private func migrateFromLegacy() {
        let defaults = UserDefaults.standard
        let legacyRepoURL = defaults.string(forKey: "repoURL") ?? ""
        let legacyIsSetUp = defaults.bool(forKey: "isSetUp")

        guard legacyIsSetUp, !legacyRepoURL.isEmpty else { return }

        let legacyGitState = GitState.loadLegacy() ?? .empty

        let config = RepoConfig(
            repoURL: legacyRepoURL,
            branch: defaults.string(forKey: "branch") ?? "main",
            authorName: defaults.string(forKey: "authorName") ?? "",
            authorEmail: defaults.string(forKey: "authorEmail") ?? "",
            vaultFolderName: defaults.string(forKey: "vaultFolderName") ?? "vault",
            customVaultBookmarkData: defaults.data(forKey: "vaultBookmark"),
            gitHubAccountLogin: activeGitHubAccountLogin.isEmpty ? nil : activeGitHubAccountLogin,
            gitState: legacyGitState
        )

        repos = [config]
        saveRepos()

        // Clean up legacy keys
        GitState.deleteLegacy()
        defaults.removeObject(forKey: "isSetUp")
        defaults.removeObject(forKey: "repoURL")
        defaults.removeObject(forKey: "branch")
        defaults.removeObject(forKey: "vaultFolderName")
        defaults.removeObject(forKey: "vaultBookmark")
    }

    private func saveProtectedRecoveries() {
        guard let data = try? JSONEncoder().encode(recoveryByRepo) else { return }
        UserDefaults.standard.set(data, forKey: "vaultbridge.protected-recoveries.v1")
    }

    static let shelteredEditsDefaultsKey = "vaultbridge.sheltered-edits.v1"

    private func saveShelteredEdits() {
        guard let data = try? JSONEncoder().encode(shelteredEditsByRepo) else { return }
        UserDefaults.standard.set(data, forKey: Self.shelteredEditsDefaultsKey)
    }

    private func recordShelteredEdits(repoID: UUID, stashMessage: String, reason: String) {
        shelteredEditsByRepo[repoID] = VaultBridgeShelteredEdits(stashMessage: stashMessage, reason: reason)
        saveShelteredEdits()
    }

    private func clearShelteredEdits(repoID: UUID) {
        guard shelteredEditsByRepo.removeValue(forKey: repoID) != nil else { return }
        saveShelteredEdits()
    }

    private func migrateLegacyGitHubAccountIfNeeded() {
        guard gitHubAccounts.isEmpty,
              let legacyToken = KeychainService.load(key: "github_pat"),
              !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !gitHubUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let account = GitHubAccount(
            login: gitHubUsername,
            displayName: gitHubDisplayName.isEmpty ? gitHubUsername : gitHubDisplayName,
            avatarURL: gitHubAvatarURL,
            email: defaultAuthorEmail
        )
        gitHubAccounts = [account]
        activeGitHubAccountLogin = account.login
        KeychainService.save(key: Self.gitHubTokenKey(for: account.login), value: legacyToken)
    }

    private func restoreActiveGitHubAccount() {
        if activeGitHubAccountLogin.isEmpty || gitHubToken(for: activeGitHubAccountLogin)?.isEmpty != false {
            activeGitHubAccountLogin = gitHubAccounts.first(where: { gitHubToken(for: $0.login)?.isEmpty == false })?.login ?? ""
        }

        guard let account = activeGitHubAccount,
              gitHubToken(for: account.login)?.isEmpty == false
        else {
            isSignedIn = false
            activeGitHubAccountLogin = ""
            gitHubRepos = []
            return
        }

        isSignedIn = true
        applyGitHubAccount(account)
    }

    private func migrateRepoAccountOwnershipIfNeeded() {
        guard !activeGitHubAccountLogin.isEmpty else { return }
        var didChange = false
        for idx in repos.indices {
            guard repos[idx].gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  repos[idx].authMethod == .gitHubPAT,
                  GitRemoteURL.parse(repos[idx].repoURL)?.isGitHub == true
            else { continue }
            repos[idx].gitHubAccountLogin = activeGitHubAccountLogin
            didChange = true
        }
        if didChange { saveRepos() }
    }

    private func applyGitHubAccount(_ account: GitHubAccount) {
        gitHubUsername = account.login
        gitHubDisplayName = account.displayName
        gitHubAvatarURL = account.avatarURL
        defaultAuthorName = account.displayName.isEmpty ? account.login : account.displayName
        defaultAuthorEmail = account.email
    }

    @discardableResult
    func saveRepos(replaceAll: Bool = false) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        do {
            let persisted: [RepoConfig]
            if replaceAll {
                try repoPersistenceStore.replaceAll(repos, at: persistedReposURL)
                persisted = repos
            } else {
                var changes: [RepoPersistenceStore.Change] = []
                for repo in repos {
                    if let original = persistedRepoSnapshot[repo.id] {
                        if original != repo { changes.append(.update(original: original, modified: repo)) }
                    } else {
                        changes.append(.add(repo))
                    }
                }
                for original in persistedRepoSnapshot.values where current[original.id] == nil {
                    changes.append(.remove(original: original))
                }
                guard !changes.isEmpty else { return true }
                persisted = try repoPersistenceStore.apply(changes, to: persistedReposURL)
            }

            // `apply` may have merged fields or records written by another
            // AppState. Reconcile those values without changing the ordering of
            // repositories already visible in this instance; then append records
            // discovered concurrently. Keeping every persisted record locally is
            // important because a later save interprets a missing snapshot ID as
            // an intentional deletion.
            let persistedByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
            let localIDs = Set(repos.map(\.id))
            repos = repos.compactMap { persistedByID[$0.id] }
                + persisted.filter { !localIDs.contains($0.id) }
            persistedRepoSnapshot = persistedByID
            return true
        } catch {
            DebugLogger.shared.error("persistence", "Could not save repository settings", detail: error.localizedDescription)
            lastError = error.localizedDescription
            showError = true
            return false
        }
    }

    func serializedRepository(repoID: UUID) throws -> SerializedGitRepository {
        guard repoIndex(id: repoID) != nil,
              let repository = gitRepositoryFactory(vaultURL(for: repoID)) as? SerializedGitRepository else {
            throw LocalGitError.notCloned
        }
        return repository
    }

    private func migrateKnownGitCredentialAccessibilityIfNeeded() {
        var keys = ["github_pat"]
        keys.append(contentsOf: gitHubAccounts.map { Self.gitHubTokenKey(for: $0.login) })
        for repo in repos {
            keys.append(contentsOf: [
                Self.repoCredentialKey(repo.id, "username"),
                Self.repoCredentialKey(repo.id, "password"),
                Self.repoCredentialKey(repo.id, "ssh_private_key"),
                Self.repoCredentialKey(repo.id, "ssh_public_key"),
                Self.repoCredentialKey(repo.id, "ssh_passphrase")
            ])
        }
        KeychainService.migrateKnownGitCredentialsIfNeeded(keys: keys)
    }

    func saveGlobalSettings() {
        let defaults = UserDefaults.standard
        defaults.set(gitHubUsername, forKey: "gitHubUsername")
        defaults.set(gitHubDisplayName, forKey: "gitHubDisplayName")
        defaults.set(gitHubAvatarURL, forKey: "gitHubAvatarURL")
        defaults.set(defaultAuthorName, forKey: "authorName")
        defaults.set(defaultAuthorEmail, forKey: "authorEmail")
        defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        defaults.set(hasSeenOnboarding, forKey: "hasSeenOnboarding")
        defaults.set(activeGitHubAccountLogin, forKey: "activeGitHubAccountLogin")
        if let accountData = try? JSONEncoder().encode(gitHubAccounts) {
            defaults.set(accountData, forKey: "gitHubAccounts")
        }

        if let bookmarkData = defaultSaveLocationBookmarkData {
            defaults.set(bookmarkData, forKey: "defaultSaveLocationBookmark")
        } else {
            defaults.removeObject(forKey: "defaultSaveLocationBookmark")
        }
    }

    // MARK: - Default Save Location

    func setDefaultSaveLocation(_ url: URL) {
        clearDefaultSaveLocation()

        guard url.startAccessingSecurityScopedResource() else { return }

        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return
        }

        defaultSaveLocationBookmarkData = bookmark
        resolvedDefaultSaveURL = url
        defaultSaveAccessingScope = true
        saveGlobalSettings()
    }

    func clearDefaultSaveLocation() {
        if defaultSaveAccessingScope, let url = resolvedDefaultSaveURL {
            url.stopAccessingSecurityScopedResource()
            defaultSaveAccessingScope = false
        }
        resolvedDefaultSaveURL = nil
        defaultSaveLocationBookmarkData = nil
        saveGlobalSettings()
    }

    var defaultSaveDisplayPath: String {
        resolvedDefaultSaveURL?.path ?? ""
    }

    var hasDefaultSaveLocation: Bool {
        resolvedDefaultSaveURL != nil
    }

    private func resolveDefaultSaveBookmark() {
        guard let bookmarkData = defaultSaveLocationBookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if url.startAccessingSecurityScopedResource() {
            defaultSaveAccessingScope = true
        }
        resolvedDefaultSaveURL = url

        if isStale {
            if let newBookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaultSaveLocationBookmarkData = newBookmark
                saveGlobalSettings()
            }
        }
    }

    // MARK: - Repo Access

    func repo(id: UUID) -> RepoConfig? {
        repos.first { $0.id == id }
    }

    func repoIndex(id: UUID) -> Int? {
        repos.firstIndex { $0.id == id }
    }

    func vaultURL(for repoID: UUID) -> URL {
        if let customURL = resolvedCustomURLs[repoID] {
            // When the bookmark points to a parent directory (clone to custom
            // location), append the repo folder name — just like `git clone`.
            if let repo = repo(id: repoID), repo.customLocationIsParent {
                return customURL.appendingPathComponent(repo.vaultFolderName, isDirectory: true)
            }
            return customURL
        }
        guard let repo = repo(id: repoID) else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        return repo.defaultVaultURL
    }

    func vaultDisplayPath(for repoID: UUID) -> String {
        if let customURL = resolvedCustomURLs[repoID] {
            if let repo = repo(id: repoID), repo.customLocationIsParent {
                return customURL.appendingPathComponent(repo.vaultFolderName).path
            }
            return customURL.path
        }
        guard let repo = repo(id: repoID) else { return "" }
        return String(localized: "On My iPhone › GitSync.md › \(repo.vaultFolderName)")
    }

    func isUsingCustomLocation(for repoID: UUID) -> Bool {
        resolvedCustomURLs[repoID] != nil
    }

    // MARK: - Vault Location

    func setCustomVaultLocation(_ url: URL, for repoID: UUID) {
        // Stop any previous security-scoped access for this repo
        clearCustomLocation(for: repoID)

        guard url.startAccessingSecurityScopedResource() else { return }

        guard let bookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            url.stopAccessingSecurityScopedResource()
            return
        }

        if let idx = repoIndex(id: repoID) {
            repos[idx].customVaultBookmarkData = bookmark
            saveRepos()
        }

        resolvedCustomURLs[repoID] = url
        accessingSecurityScope.insert(repoID)
    }

    func clearCustomLocation(for repoID: UUID) {
        if accessingSecurityScope.contains(repoID), let url = resolvedCustomURLs[repoID] {
            url.stopAccessingSecurityScopedResource()
            accessingSecurityScope.remove(repoID)
        }
        resolvedCustomURLs.removeValue(forKey: repoID)
        if let idx = repoIndex(id: repoID) {
            repos[idx].customVaultBookmarkData = nil
            saveRepos()
        }
    }

    /// Moves a repo's vault to a new parent directory.
    ///
    /// The caller must already hold a security-scoped resource on `newParentURL`
    /// (typically from a `fileImporter` selection). On success, ownership of
    /// that scope is transferred to `AppState` and tracked in
    /// `accessingSecurityScope`. On failure the caller is responsible for
    /// releasing it.
    func moveVaultLocation(for repoID: UUID, to newParentURL: URL, bookmark: Data) throws {
        guard let idx = repoIndex(id: repoID) else {
            throw MoveVaultError.repoNotFound
        }

        let repo = repos[idx]
        let currentURL = vaultURL(for: repoID)
        let destinationURL = newParentURL.appendingPathComponent(repo.vaultFolderName, isDirectory: true)

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw MoveVaultError.destinationExists
        }

        // If the source vault lives in a user-picked custom location, we need
        // its security scope live during the move. The default in-app vault
        // (Documents directory) is always accessible without a scope.
        if resolvedCustomURLs[repoID] != nil, !accessingSecurityScope.contains(repoID) {
            throw MoveVaultError.bookmarkFailed
        }

        try FileManager.default.moveItem(at: currentURL, to: destinationURL)

        // Release the old custom-location scope (if any) now that the source
        // is gone, then hand the new parent's scope — already held by the
        // caller — over to AppState.
        clearCustomLocation(for: repoID)

        repos[idx].customVaultBookmarkData = bookmark
        repos[idx].customLocationIsParent = true
        saveRepos()

        resolvedCustomURLs[repoID] = newParentURL
        accessingSecurityScope.insert(repoID)

        detectChanges(repoID: repoID)
    }

    enum MoveVaultError: LocalizedError {
        case repoNotFound
        case destinationExists
        case bookmarkFailed

        var errorDescription: String? {
            switch self {
            case .repoNotFound: String(localized: "Repository not found")
            case .destinationExists: String(localized: "A folder with the same name already exists at the chosen location")
            case .bookmarkFailed: String(localized: "Could not access the selected folder")
            }
        }
    }

    /// Moves an existing vault folder to a timestamped sibling instead of
    /// deleting it, so replacing a working copy can never destroy the only
    /// copy of local work. The backup remains visible and deletable in Files.
    @discardableResult
    static func moveAsideExistingVault(at url: URL) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let parent = url.deletingLastPathComponent()
        var destination = parent.appendingPathComponent("\(url.lastPathComponent)-backup-\(stamp)", isDirectory: true)
        var attempt = 1
        while fm.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent("\(url.lastPathComponent)-backup-\(stamp)-\(attempt)", isDirectory: true)
            attempt += 1
        }
        try fm.moveItem(at: url, to: destination)
        DebugLogger.shared.info("clone", "Preserved existing vault folder before clone", detail: destination.lastPathComponent)
        return destination
    }

    private func resolveVaultBookmark(for repoID: UUID) {
        guard let repo = repo(id: repoID),
              let bookmarkData = repo.customVaultBookmarkData else { return }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if url.startAccessingSecurityScopedResource() {
            accessingSecurityScope.insert(repoID)
        }
        resolvedCustomURLs[repoID] = url

        if isStale {
            if let newBookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ), let idx = repoIndex(id: repoID) {
                repos[idx].customVaultBookmarkData = newBookmark
                saveRepos()
            }
        }
    }

    // MARK: - Filesystem Validation

    /// Check all repos marked as cloned and reset any whose `.git` directory
    /// has been deleted from the filesystem (e.g. via Files app).
    func validateClonedRepos() {
        if isDemoMode { return }
        var didChange = false
        for (index, repo) in repos.enumerated() where repo.isCloned {
            // A vault behind a security-scoped bookmark can be temporarily
            // unreachable (file provider not ready, stale bookmark after a
            // restore). Retry resolution here; if the real folder still cannot
            // be reached, skip validation entirely — `vaultURL` would fall back
            // to the in-app Documents path, whose missing `.git` would wrongly
            // reset a healthy external clone and funnel the user into re-cloning.
            if repo.customVaultBookmarkData != nil, resolvedCustomURLs[repo.id] == nil {
                resolveVaultBookmark(for: repo.id)
                if resolvedCustomURLs[repo.id] == nil { continue }
            }

            let vaultDir = vaultURL(for: repo.id)
            let gitService = gitRepositoryFactory(vaultDir)

            if !gitService.hasGitDirectory {
                repos[index].gitState = .empty
                changeCounts[repo.id] = 0
                statusEntriesByRepo[repo.id] = []
                syncStateByRepo[repo.id] = .unknown
                diffByRepo[repo.id] = .empty
                branchesByRepo[repo.id] = .empty
                conflictSessionByRepo[repo.id] = .none
                commitHistoryByRepo[repo.id] = []
                commitHistoryHasMoreByRepo[repo.id] = false
                commitDetailByRepo[repo.id] = [:]
                stashesByRepo[repo.id] = []
                didChange = true
            }
        }
        if didChange {
            saveRepos()
        }
    }

    // MARK: - Change Detection

    func scheduleInitialChangeDetectionIfNeeded() {
        guard !didScheduleInitialChangeDetection else { return }
        didScheduleInitialChangeDetection = true
        refreshClonedRepos(deferredBy: 0.75, skipIfRecentlyStartedWithin: 10)
    }

    func refreshClonedRepos(deferredBy delay: TimeInterval = 0, skipIfRecentlyStartedWithin interval: TimeInterval? = nil) {
        let repoIDs = repos.filter(\.isCloned).map(\.id)
        guard !repoIDs.isEmpty else { return }

        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            for repoID in repoIDs {
                detectChanges(repoID: repoID, skipIfRecentlyStartedWithin: interval)
            }
        }
    }

    func detectChanges(repoID: UUID, skipIfRecentlyStartedWithin interval: TimeInterval? = nil) {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }
        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            // .git directory was removed — reset cloned state
            if let idx = repoIndex(id: repoID) {
                repos[idx].gitState = .empty
                saveRepos()
            }
            changeCounts[repoID] = 0
            statusEntriesByRepo[repoID] = []
            syncStateByRepo[repoID] = .unknown
            diffByRepo[repoID] = .empty
            branchesByRepo[repoID] = .empty
            conflictSessionByRepo[repoID] = .none
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            commitDetailByRepo[repoID] = [:]
            stashesByRepo[repoID] = []
            return
        }

        let now = Date()
        if let interval,
           repositoryInspectionIsFresh(repoID: repoID, within: interval, now: now) {
            return
        }

        if changeDetectionInFlight.contains(repoID) {
            pendingChangeDetection.insert(repoID)
            return
        }
        changeDetectionInFlight.insert(repoID)
        lastChangeDetectionStartedAt[repoID] = now

        let startedAt = now
        let startedGeneration = repoMutationGeneration[repoID] ?? 0
        let repoName = repo.displayName
        Task(priority: .utility) {
            do {
                let info = try await gitService.repoInfo()
                let isStale = startedGeneration != (repoMutationGeneration[repoID] ?? 0)
                if !isStale {
                    if let index = repoIndex(id: repoID) {
                        var shouldPersist = false
                        if !info.remoteCommitSHA.isEmpty,
                           repos[index].gitState.remoteCommitSHA != info.remoteCommitSHA {
                            repos[index].gitState.remoteCommitSHA = info.remoteCommitSHA
                            shouldPersist = true
                        }
                        if shouldPersist { saveRepos() }
                    }
                    changeCounts[repoID] = info.changeCount
                    statusEntriesByRepo[repoID] = info.statusEntries
                    syncStateByRepo[repoID] = info.syncState
                    diffByRepo[repoID] = .empty
                    markRepositoryInspectionCompleted(repoID: repoID)
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed > 2 {
                    let staleSuffix = isStale ? ", discarded stale result" : ""
                    DebugLogger.shared.info(
                        "status",
                        "Status refresh was slow",
                        detail: "\(repoName): \(String(format: "%.1f", elapsed))s, \(info.statusEntries.count) entries\(staleSuffix)"
                    )
                }
            } catch {
                let isStale = startedGeneration != (repoMutationGeneration[repoID] ?? 0)
                if !isStale {
                    changeCounts[repoID] = 0
                    statusEntriesByRepo[repoID] = []
                    syncStateByRepo[repoID] = .unknown
                    diffByRepo[repoID] = .empty
                    branchesByRepo[repoID] = .empty
                    conflictSessionByRepo[repoID] = .none
                    commitHistoryByRepo[repoID] = []
                    commitHistoryHasMoreByRepo[repoID] = false
                    commitDetailByRepo[repoID] = [:]
                    stashesByRepo[repoID] = []
                }
            }

            let shouldRunAgain = pendingChangeDetection.remove(repoID) != nil
            changeDetectionInFlight.remove(repoID)
            if shouldRunAgain {
                detectChanges(repoID: repoID)
            }
        }
    }

    /// Shares repository-inspection freshness between the dashboard sync
    /// coordinator and detail screens. Without this handoff, opening a vault
    /// immediately after the dashboard inspected it started a second full
    /// working-tree traversal.
    func markRepositoryInspectionStarted(repoID: UUID, at date: Date = Date()) {
        lastChangeDetectionStartedAt[repoID] = date
    }

    func markRepositoryInspectionCompleted(repoID: UUID, at date: Date = Date()) {
        lastRepositoryInspectionCompletedAt[repoID] = date
    }

    func repositoryInspectionIsFresh(
        repoID: UUID,
        within interval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        let latest = [
            lastChangeDetectionStartedAt[repoID],
            lastRepositoryInspectionCompletedAt[repoID]
        ]
        .compactMap { $0 }
        .max()
        guard let latest else { return false }
        return now.timeIntervalSince(latest) < interval
    }

    func fetchRemote(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }
        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)
        let credentials = authPayload(for: repo)
        guard gitService.hasGitDirectory else { return }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = "Checking the server without changing phone files…"
        defer { isSyncing = false; syncingRepoID = nil }
        do {
            let info = try await serializedRepository(repoID: repoID).withLease { repository in
                try await repository.fetchRemote(pat: credentials)
                return try await repository.repoInfo()
            }
            if let index = repoIndex(id: repoID) {
                if !info.remoteCommitSHA.isEmpty {
                    repos[index].gitState.remoteCommitSHA = info.remoteCommitSHA
                }
                repos[index].gitState.lastRemoteCheckDate = Date()
                repos[index].gitState.lastSyncDate = Date()
                saveRepos()
            }
            changeCounts[repoID] = info.changeCount
            statusEntriesByRepo[repoID] = info.statusEntries
            syncStateByRepo[repoID] = info.syncState
            syncProgress = info.remoteCommitSHA.isEmpty
                ? "Server check complete, but no server branch was found."
                : "Server checked and verified at \(String(info.remoteCommitSHA.prefix(7))). Phone files were not changed."
            setPullOutcome(repoID: repoID, kind: .upToDate, message: syncProgress)
        } catch is CancellationError {
            syncProgress = "Server check cancelled"
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadUnifiedDiff(repoID: UUID, path: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            diffByRepo[repoID] = .empty
            return
        }
        if isDemoMode {
            diffByRepo[repoID] = .empty
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            diffByRepo[repoID] = .empty
            return
        }

        do {
            diffByRepo[repoID] = try await gitService.unifiedDiff(path: path)
        } catch {
            diffByRepo[repoID] = .empty
            showError(message: error.localizedDescription)
        }
    }

    func loadBranches(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            branchesByRepo[repoID] = .empty
            return
        }
        if isDemoMode {
            branchesByRepo[repoID] = .empty
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            branchesByRepo[repoID] = .empty
            return
        }

        do {
            branchesByRepo[repoID] = try await gitService.listBranches()
        } catch {
            branchesByRepo[repoID] = .empty
            showError(message: error.localizedDescription)
        }
    }

    func loadConflictSession(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            conflictSessionByRepo[repoID] = .none
            return
        }
        if isDemoMode {
            conflictSessionByRepo[repoID] = .none
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            conflictSessionByRepo[repoID] = .none
            return
        }

        do {
            conflictSessionByRepo[repoID] = try await gitService.conflictSession()
        } catch {
            conflictSessionByRepo[repoID] = .none
            showError(message: error.localizedDescription)
        }
    }

    func resolveConflictFile(repoID: UUID, path: String, strategy: ConflictResolutionStrategy) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.resolveConflict(path: path, strategy: strategy)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func loadConflictDetail(repoID: UUID, path: String) async -> ConflictFileDetail? {
        guard let repo = repo(id: repoID), repo.isCloned else { return nil }
        if isDemoMode { return nil }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else { return nil }

        do {
            return try await gitService.conflictDetail(path: path)
        } catch {
            showError(message: error.localizedDescription)
            return nil
        }
    }

    func resolveConflictWithContent(
        repoID: UUID,
        path: String,
        content: Data,
        additionalPathsToRemove: [String] = []
    ) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.resolveConflictWithContent(
                path: path,
                content: content,
                additionalPathsToRemove: additionalPathsToRemove
            )
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    @discardableResult
    func resolveConflictKeepingBoth(
        repoID: UUID,
        detail: ConflictFileDetail,
        serverCopyPath: String
    ) async -> Bool {
        guard repo(id: repoID)?.isCloned == true,
              let phone = detail.ours,
              let server = detail.theirs else { return false }
        do {
            let serialized = try serializedRepository(repoID: repoID)
            try await serialized.withLease { repository in
                let primaryPath = phone.path
                try await repository.resolveConflictWithContent(
                    path: primaryPath,
                    content: phone.content ?? Data(),
                    additionalPathsToRemove: detail.allPaths.filter { $0 != primaryPath }
                )
                try await repository.resolveConflictWithContent(
                    path: serverCopyPath,
                    content: server.content ?? Data(),
                    additionalPathsToRemove: []
                )
            }
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            return true
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "conflict")
            return false
        }
    }

    /// Auto-commit local edits, then attempt a merge with the remote-tracking
    /// branch. This is the unblock path from the "Local edits detected" banner:
    /// the user can't pull because there are uncommitted changes, and we'd
    /// rather create a real commit + merge (so any conflicts surface in the
    /// conflict editor) than block them with no in-app way forward.
    func commitLocalAndAttemptMerge(repoID: UUID, message: String) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = trimmed.isEmpty
            ? String(localized: "Local changes from GitSync.md")
            : trimmed
        let currentBranch = repo.gitState.branch.isEmpty ? "main" : repo.gitState.branch
        let upstreamName = "origin/\(currentBranch)"
        let credentials = authPayload(for: repo)

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Committing local changes...")
        pullOutcomeByRepo.removeValue(forKey: repoID)
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let execution = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                try await repository.stageAll()

                let committedSHA: String?
                do {
                    committedSHA = try await repository.commitLocal(
                        message: commitMessage,
                        authorName: repo.authorName,
                        authorEmail: repo.authorEmail
                    )
                } catch LocalGitError.noChanges {
                    committedSHA = nil
                }

                let mergeResult: MergeResult
                do {
                    mergeResult = try await repository.mergeBranch(
                        name: upstreamName,
                        authorName: repo.authorName,
                        authorEmail: repo.authorEmail
                    )
                } catch LocalGitError.mergeConflictsDetected {
                    return CommitMergeExecution(
                        committedSHA: committedSHA,
                        mergeResult: nil,
                        mergeConflicted: true,
                        mergeErrorMessage: nil,
                        pushErrorMessage: nil
                    )
                } catch {
                    return CommitMergeExecution(
                        committedSHA: committedSHA,
                        mergeResult: nil,
                        mergeConflicted: false,
                        mergeErrorMessage: error.localizedDescription,
                        pushErrorMessage: nil
                    )
                }

                var pushErrorMessage: String?
                if committedSHA != nil || mergeResult.kind != .upToDate {
                    do {
                        try await repository.pushCurrentBranch(pat: credentials)
                    } catch {
                        pushErrorMessage = error.localizedDescription
                    }
                }
                return CommitMergeExecution(
                    committedSHA: committedSHA,
                    mergeResult: mergeResult,
                    mergeConflicted: false,
                    mergeErrorMessage: nil,
                    pushErrorMessage: pushErrorMessage
                )
            }

            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                if let mergeResult = execution.mergeResult,
                   mergeResult.kind == .fastForwarded || mergeResult.kind == .mergeCommitted {
                    repos[currentIndex].gitState.commitSHA = mergeResult.newCommitSHA
                } else if let committedSHA = execution.committedSHA {
                    repos[currentIndex].gitState.commitSHA = committedSHA
                }
                if execution.committedSHA != nil
                    || execution.mergeConflicted
                    || execution.mergeResult.map({ $0.kind != .upToDate }) == true {
                    repos[currentIndex].gitState.lastSyncDate = Date()
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                }
            }

            if execution.mergeConflicted {
                await loadConflictSession(repoID: repoID)
                setPullOutcome(
                    repoID: repoID,
                    kind: .diverged,
                    message: String(localized: "Merge has conflicts — tap a conflicted file to resolve")
                )
            } else if let message = execution.mergeErrorMessage ?? execution.pushErrorMessage {
                setPullOutcome(repoID: repoID, kind: .failed, message: message)
                showError(message: message)
            } else if let mergeResult = execution.mergeResult {
                switch mergeResult.kind {
                case .upToDate:
                    setPullOutcome(
                        repoID: repoID,
                        kind: execution.committedSHA == nil ? .upToDate : .fastForwarded,
                        message: execution.committedSHA == nil
                            ? String(localized: "Already up to date")
                            : String(localized: "Committed and pushed successfully")
                    )
                case .fastForwarded, .mergeCommitted:
                    setPullOutcome(
                        repoID: repoID,
                        kind: .fastForwarded,
                        message: String(localized: "Merged and pushed successfully")
                    )
                }
            }

            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func cancelPendingLFSAutoTracking() {
        pendingLFSAutoTrackingConfirmation = nil
    }

    @discardableResult
    private func handleSSHHostKeyTrustIfNeeded(
        _ error: Error,
        repoID: UUID,
        operation: SSHHostKeyTrustRequest.Operation
    ) -> Bool {
        guard case LocalGitError.sshHostKeyTrustRequired(let trustError) = error else {
            return false
        }
        pendingSSHHostKeyTrustRequest = SSHHostKeyTrustRequest(
            repoID: repoID,
            operation: operation,
            trustError: trustError
        )
        syncProgress = String(localized: "SSH host key needs trust")
        return true
    }

    func trustPendingSSHHostKeyAndRetry() async {
        guard let request = pendingSSHHostKeyTrustRequest else { return }
        do {
            try sshHostKeyTrustStore.trust(
                fingerprint: request.fingerprintToTrust,
                host: request.host,
                port: request.port
            )
            DebugLogger.shared.info(
                "security",
                "Trusted SSH host key",
                detail: "\(request.host):\(request.port) \(request.fingerprintToTrust)"
            )
        } catch {
            pendingSSHHostKeyTrustRequest = nil
            showError(message: error.localizedDescription, category: "security")
            return
        }

        let operation = request.operation
        let repoID = request.repoID
        pendingSSHHostKeyTrustRequest = nil

        switch operation {
        case .clone:
            await clone(repoID: repoID)
        case .pull:
            _ = await pull(repoID: repoID)
        case .pushCurrentBranch:
            _ = await pushCurrentBranch(repoID: repoID)
        case .pushCommit(let message):
            _ = await push(repoID: repoID, message: message)
        }
    }

    func cancelPendingSSHHostKeyTrust() {
        pendingSSHHostKeyTrustRequest = nil
    }

    func loadStashes(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            stashesByRepo[repoID] = []
            return
        }
        if isDemoMode {
            stashesByRepo[repoID] = []
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            stashesByRepo[repoID] = []
            return
        }

        do {
            stashesByRepo[repoID] = try await gitService.listStashes()
        } catch {
            stashesByRepo[repoID] = []
            showError(message: error.localizedDescription)
        }
    }

    func saveStash(repoID: UUID, message: String = "", includeUntracked: Bool = true) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.saveStash(
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail,
                includeUntracked: includeUntracked
            )
            detectChanges(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func applyStash(repoID: UUID, index: Int, reinstateIndex: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.applyStash(index: index, reinstateIndex: reinstateIndex)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func popStash(repoID: UUID, index: Int, reinstateIndex: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.popStash(index: index, reinstateIndex: reinstateIndex)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            await loadStashes(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    func dropStash(repoID: UUID, index: Int) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.dropStash(index: index)
            await loadStashes(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadTags(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            tagsByRepo[repoID] = []
            return
        }
        if isDemoMode {
            tagsByRepo[repoID] = []
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            tagsByRepo[repoID] = []
            return
        }

        do {
            tagsByRepo[repoID] = try await gitService.listTags()
        } catch {
            tagsByRepo[repoID] = []
            showError(message: error.localizedDescription)
        }
    }

    func createTag(repoID: UUID, name: String, targetOID: String? = nil, message: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            _ = try await gitService.createTag(
                name: name,
                targetOID: targetOID,
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            await loadTags(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func deleteTag(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.deleteTag(name: name)
            await loadTags(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func pushTag(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.pushTag(name: name, pat: authPayload(for: repo))
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func loadCommitHistory(repoID: UUID, pageSize: Int = 30, reset: Bool = false) async {
        guard let repo = repo(id: repoID), repo.isCloned else {
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            return
        }
        if isDemoMode {
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            return
        }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            commitHistoryByRepo[repoID] = []
            commitHistoryHasMoreByRepo[repoID] = false
            return
        }

        let existing = reset ? [] : (commitHistoryByRepo[repoID] ?? [])
        let skip = existing.count

        do {
            let page = try await gitService.commitHistory(limit: pageSize, skip: skip)
            let merged = reset ? page : (existing + page)
            commitHistoryByRepo[repoID] = merged
            commitHistoryHasMoreByRepo[repoID] = page.count == pageSize
            if reset {
                commitDetailByRepo[repoID] = [:]
            }
        } catch {
            if reset {
                commitHistoryByRepo[repoID] = []
                commitHistoryHasMoreByRepo[repoID] = false
                commitDetailByRepo[repoID] = [:]
            }
            showError(message: error.localizedDescription)
        }
    }

    func loadCommitDetail(repoID: UUID, oid: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let trimmedOID = oid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOID.isEmpty else { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else { return }

        do {
            let detail = try await gitService.commitDetail(oid: trimmedOID)
            var existing = commitDetailByRepo[repoID] ?? [:]
            existing[trimmedOID] = detail
            commitDetailByRepo[repoID] = existing
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func createBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.createBranch(name: name)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func switchBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        isSyncing = true; syncingRepoID = repoID; syncProgress = String(localized: "Switching branch...")
        defer { isSyncing = false; syncingRepoID = nil }
        do {
            let serialized = try serializedRepository(repoID: repoID)
            let info = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                try await repository.switchBranch(name: name)
                return try await repository.repoInfo()
            }
            markRepositoryMutated(repoID: repoID)
            if let index = repoIndex(id: repoID) {
                repos[index].gitState.branch = info.branch
                repos[index].gitState.commitSHA = info.commitSHA
                saveRepos(); clearCommitHistoryCache(for: repoID)
            }
            detectChanges(repoID: repoID); await loadBranches(repoID: repoID)
        } catch { showError(message: error.localizedDescription) }
    }

    func deleteBranch(repoID: UUID, name: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            try await gitService.deleteBranch(name: name)
            await loadBranches(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func mergeBranch(repoID: UUID, from branchName: String) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let gitService = gitRepositoryFactory(vaultURL(for: repoID))
        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Merging branch...")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let result = try await gitService.mergeBranch(
                name: branchName,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }

            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }
    }

    /// "Combine Phone and Server" from the drawer. The server is contacted
    /// first so a network failure cannot strand edits in a shelf; then the
    /// phone is saved, remaining live edits are sheltered, histories are
    /// merged, and the shelter is put back. Nothing is uploaded.
    func mergeWithRemote(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let credentials = authPayload(for: repo)
        let authorName = repo.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorEmail = repo.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorName.isEmpty, !authorEmail.isEmpty else {
            showError(message: "Set a Git author name and email before saving phone changes.")
            return
        }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Checking the server before combining…")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let execution = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }

                // Network first. Until this succeeds nothing on the phone has
                // moved, so an offline device simply sees an error.
                let plan = try await repository.pullPlan(pat: credentials)
                if plan.action == .remoteBranchMissing {
                    throw LocalGitError.pullRemoteBranchMissing(plan.branch)
                }

                var committedSHA: String?
                var info = try await repository.repoInfo()
                var pass = 0
                while !info.statusEntries.isEmpty && pass < 3 {
                    pass += 1
                    try await repository.stageChanges(info.statusEntries, lfsAutoTrack: true)
                    do {
                        committedSHA = try await repository.commitLocal(
                            message: "VaultBridge checkpoint before server merge",
                            authorName: authorName,
                            authorEmail: authorEmail
                        )
                        try await Task.sleep(for: .milliseconds(400))
                    } catch LocalGitError.noChanges {
                        // The status scan can observe a File Provider/editor
                        // write whose final bytes still equal HEAD. Reinspect
                        // before deciding whether anything must be shelved.
                    }
                    info = try await repository.repoInfo()
                }

                var shelf: GitStashEntry?
                if !info.statusEntries.isEmpty {
                    do {
                        shelf = try await repository.saveStash(
                            message: "VaultBridge temporary shelf before server merge \(UUID().uuidString)",
                            authorName: authorName,
                            authorEmail: authorEmail,
                            includeUntracked: true
                        )
                    } catch LocalGitError.stashNothingToSave {
                        // A final status refresh below decides whether these
                        // were merely stale stat/File Provider notifications.
                    }
                    info = try await repository.repoInfo()
                    guard info.statusEntries.isEmpty else {
                        throw LocalGitError.mergeBlockedByLocalChanges
                    }
                }

                do {
                    let mergeResult: MergeResult?
                    let mergeConflicted: Bool
                    do {
                        mergeResult = try await repository.mergeBranch(
                            name: "origin/\(plan.branch)",
                            authorName: authorName,
                            authorEmail: authorEmail
                        )
                        mergeConflicted = false
                    } catch LocalGitError.mergeConflictsDetected {
                        mergeResult = nil
                        mergeConflicted = true
                    }

                    var shelfRestored = false
                    var shelfConflicted = false
                    if !mergeConflicted, let shelf {
                        let applied = try await repository.applyStash(index: shelf.index, reinstateIndex: true)
                        shelfRestored = applied.kind == .applied
                        shelfConflicted = applied.kind == .conflicts
                        // The shelf stays as a recovery copy. The user can
                        // remove it from the expert Stash list later.
                    }
                    return VaultBridgeSafeMergeExecution(
                        committedSHA: committedSHA,
                        remoteCommitSHA: plan.remoteCommitSHA,
                        mergeResult: mergeResult,
                        mergeConflicted: mergeConflicted,
                        shelvedEdits: shelf != nil,
                        shelfRestored: shelfRestored,
                        shelfConflicted: shelfConflicted,
                        shelfMessage: shelf?.message
                    )
                } catch {
                    if let shelf {
                        throw VaultBridgeStrandedShelfError(underlying: error, stashMessage: shelf.message)
                    }
                    throw error
                }
            }

            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                if let result = execution.mergeResult {
                    repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                } else if let committedSHA = execution.committedSHA {
                    repos[currentIndex].gitState.commitSHA = committedSHA
                }
                if let committedSHA = execution.committedSHA, !committedSHA.isEmpty {
                    repos[currentIndex].gitState.localCheckpointDate = Date()
                }
                if !execution.remoteCommitSHA.isEmpty {
                    repos[currentIndex].gitState.remoteCommitSHA = execution.remoteCommitSHA
                }
                repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }

            if execution.shelvedEdits, !execution.shelfRestored, !execution.shelfConflicted, let shelfMessage = execution.shelfMessage {
                recordShelteredEdits(
                    repoID: repoID,
                    stashMessage: shelfMessage,
                    reason: "Kept safe while combining with the server"
                )
            }

            if execution.mergeConflicted {
                await loadConflictSession(repoID: repoID)
                let count = conflictSessionByRepo[repoID]?.unmergedPaths.count ?? 0
                setPullOutcome(repoID: repoID, kind: .mergeConflicts, message: Self.conflictChoiceMessage(count: count)
                    + (execution.shelvedEdits ? " Your latest edits are sheltered and come back automatically once you finish." : ""))
            } else if execution.shelfConflicted {
                await loadConflictSession(repoID: repoID)
                setPullOutcome(repoID: repoID, kind: .mergeConflicts, message: "Server changes were combined. Putting your latest edits back needs your choice for some notes.")
            } else if let result = execution.mergeResult {
                let saved = execution.committedSHA.map { " Phone edits were saved as \(String($0.prefix(7)))." } ?? ""
                let restored = execution.shelfRestored ? " Your latest edits were put back." : ""
                let kind: PullOutcomeKind
                let message: String
                switch result.kind {
                case .upToDate:
                    kind = .upToDate
                    message = "This phone already has everything on the server."
                case .fastForwarded:
                    kind = .fastForwarded
                    message = "Newer server notes were brought onto this phone. Nothing was uploaded."
                case .mergeCommitted:
                    kind = .merged
                    message = "Phone and server changes were combined on this phone. Nothing was uploaded."
                }
                setPullOutcome(repoID: repoID, kind: kind, message: message + saved + restored)
            }
            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: "Combine cancelled")
        } catch LocalGitError.mergeBlockedByLocalChanges {
            // The fetch completed before the safe-combine path discovered a
            // working-tree problem. Keep that successful network check
            // visible instead of incorrectly reverting the card to “server
            // not checked yet.”
            markVaultBridgeRemoteCheckSucceeded(repoID: repoID)
            let message = "Some notes were still being written, so VaultBridge did not risk overwriting them. Wait a moment and try again."
            setPullOutcome(repoID: repoID, kind: .blockedByLocalChanges, message: message)
            showError(message: message)
        } catch let stranded as VaultBridgeStrandedShelfError {
            markRepositoryMutated(repoID: repoID)
            recordShelteredEdits(
                repoID: repoID,
                stashMessage: stranded.stashMessage,
                reason: "Kept safe while combining with the server"
            )
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            let message = stranded.underlying.localizedDescription
                + " Your latest edits are sheltered and will be put back by the next sync."
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            showError(message: message)
        } catch {
            setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
            showError(message: error.localizedDescription)
        }
    }

    nonisolated static func conflictChoiceMessage(count: Int) -> String {
        switch count {
        case 0: "Combining needs your choice between the phone and server copies."
        case 1: "1 note needs your choice between the phone and server copies."
        default: "\(count) notes need your choice between the phone and server copies."
        }
    }

    /// Expert "Force Save": rebuilds the index from the last commit and the
    /// files on disk, then commits. Clears stale entries the per-file path
    /// cannot address. Never touches files on disk and never uploads.
    @discardableResult
    func forceSaveOnPhone(repoID: UUID, message: String = "") async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return false }
        let authorName = repo.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorEmail = repo.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorName.isEmpty, !authorEmail.isEmpty else {
            showError(message: "Set a Git author name and email for \(repo.displayName) before saving.")
            return false
        }
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "VaultBridge forced save \(ISO8601DateFormatter().string(from: Date()))"
            : message
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Rebuilding the save from the files on disk…")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let sha: String? = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }
                try await repository.rebuildIndexFromWorkingTree(lfsAutoTrack: true)
                do {
                    return try await repository.commitLocal(
                        message: commitMessage,
                        authorName: authorName,
                        authorEmail: authorEmail
                    )
                } catch LocalGitError.noChanges {
                    return nil
                }
            }
            markRepositoryMutated(repoID: repoID)
            if let sha, let index = repoIndex(id: repoID) {
                repos[index].gitState.commitSHA = sha
                repos[index].gitState.localCheckpointDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }
            detectChanges(repoID: repoID)
            if let sha {
                syncProgress = "Force-saved on this iPhone as \(String(sha.prefix(7))). Not uploaded."
                setPullOutcome(repoID: repoID, kind: .saved, message: syncProgress)
            } else {
                syncProgress = "Git already holds exactly what is on disk. Stale entries were cleared; nothing new to save."
                setPullOutcome(repoID: repoID, kind: .saved, message: syncProgress)
            }
            return true
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: "Force save cancelled")
            return false
        } catch {
            showError(message: error.localizedDescription, category: "commit")
            return false
        }
    }

    /// Puts edits that were sheltered by a combine or replacement back into
    /// the working tree. Safe to call when nothing is sheltered.
    @discardableResult
    func restoreShelteredEdits(repoID: UUID, presentsErrors: Bool = true) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode,
              let sheltered = shelteredEditsByRepo[repoID] else { return false }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Putting sheltered edits back…")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let result: StashApplyResult? = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }
                let stashes = try await repository.listStashes()
                guard let stash = stashes.first(where: { $0.message == sheltered.stashMessage }) else {
                    return nil
                }
                return try await repository.applyStash(index: stash.index, reinstateIndex: true)
            }

            markRepositoryMutated(repoID: repoID)
            clearShelteredEdits(repoID: repoID)
            switch result?.kind {
            case nil:
                setPullOutcome(repoID: repoID, kind: .restored, message: "The shelter was already emptied. Nothing to put back.")
            case .applied?:
                setPullOutcome(repoID: repoID, kind: .restored, message: "Sheltered edits are back in the vault. A copy stays in the expert Stash list until you remove it.")
            case .conflicts?:
                await loadConflictSession(repoID: repoID)
                let count = conflictSessionByRepo[repoID]?.unmergedPaths.count ?? 0
                setPullOutcome(repoID: repoID, kind: .mergeConflicts, message: "Putting sheltered edits back needs your choice. " + Self.conflictChoiceMessage(count: count))
            }
            detectChanges(repoID: repoID)
            return result?.kind != .conflicts
        } catch is CancellationError {
            return false
        } catch {
            if presentsErrors {
                showError(message: error.localizedDescription, category: "recovery")
            } else {
                DebugLogger.shared.error("recovery", error.localizedDescription)
            }
            return false
        }
    }

    /// Emergency replacement is only exposed through this guarded operation.
    /// The server is contacted first, then the current commit and every dirty
    /// or untracked file are preserved, and only then is the checked-out
    /// branch moved to the server copy. The remote is never modified.
    func replacePhoneCopyWithServer(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Checking the server, then protecting phone files…")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let credentials = authPayload(for: repo)
            let stashMessage = "VaultBridge protected recovery \(UUID().uuidString)"
            let serialized = try serializedRepository(repoID: repoID)
            let result = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }

                // Reach the server before touching anything. The plan also
                // names the branch that is actually checked out, so the
                // replacement can never move a different branch.
                let plan = try await repository.pullPlan(pat: credentials)
                if plan.action == .remoteBranchMissing {
                    throw LocalGitError.pullRemoteBranchMissing(plan.branch)
                }

                let info = try await repository.repoInfo()
                var stash: GitStashEntry?
                if info.changeCount > 0 {
                    stash = try await repository.saveStash(
                        message: stashMessage,
                        authorName: repo.authorName,
                        authorEmail: repo.authorEmail,
                        includeUntracked: true
                    )
                }
                do {
                    let headRecovery = try await repository.createRecoveryReference()
                    let newSHA = try await repository.hardReset(referenceName: "refs/remotes/origin/\(plan.branch)")
                    let recovery = GitRecoverySnapshot(
                        referenceName: headRecovery.referenceName,
                        commitSHA: headRecovery.commitSHA,
                        stashMessage: stash?.message
                    )
                    return (recovery, newSHA)
                } catch {
                    if let stash {
                        throw VaultBridgeStrandedShelfError(underlying: error, stashMessage: stash.message)
                    }
                    throw error
                }
            }

            recoveryByRepo[repoID] = result.0
            saveProtectedRecoveries()
            markRepositoryMutated(repoID: repoID)
            if let index = repoIndex(id: repoID) {
                repos[index].gitState.commitSHA = result.1
                repos[index].gitState.remoteCommitSHA = result.1
                repos[index].gitState.lastRemoteCheckDate = Date()
                repos[index].gitState.lastSyncDate = Date()
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(repoID: repoID, kind: .restored, message: String(localized: "This phone now matches the server. The previous phone state is protected and can be restored from Git Tools."))
        } catch let stranded as VaultBridgeStrandedShelfError {
            markRepositoryMutated(repoID: repoID)
            recordShelteredEdits(
                repoID: repoID,
                stashMessage: stranded.stashMessage,
                reason: "Kept safe during an emergency replacement"
            )
            detectChanges(repoID: repoID)
            let message = stranded.underlying.localizedDescription
                + " Your unsaved edits are sheltered and will be put back by the next sync."
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            showError(message: message, category: "recovery")
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: "Replacement cancelled before any phone file changed.")
        } catch {
            showError(message: error.localizedDescription, category: "recovery")
        }
    }

    /// Returns to the protected phone backup. The state being left behind is
    /// itself protected first (commit reference plus a stash of live edits),
    /// so Restore is always reversible and never discards vault contents.
    func restoreProtectedRecovery(repoID: UUID) async {
        guard let repo = repo(id: repoID), let recovery = recoveryByRepo[repoID], !isDemoMode else { return }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Protecting current files, then restoring the backup…")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let outcome = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let session = try await repository.conflictSession()
                guard !session.isActive else {
                    throw LocalGitError.conflictSessionInProgress(session.kind)
                }

                let info = try await repository.repoInfo()
                var currentStash: GitStashEntry?
                if info.changeCount > 0 {
                    currentStash = try await repository.saveStash(
                        message: "VaultBridge protected recovery before restore \(UUID().uuidString)",
                        authorName: repo.authorName,
                        authorEmail: repo.authorEmail,
                        includeUntracked: true
                    )
                }
                do {
                    let currentSnapshot = try await repository.createRecoveryReference()
                    let sha = try await repository.hardReset(referenceName: recovery.referenceName)
                    var reapplied = true
                    if let stashMessage = recovery.stashMessage {
                        let stashes = try await repository.listStashes()
                        if let stash = stashes.first(where: { $0.message == stashMessage }) {
                            reapplied = try await repository.applyStash(index: stash.index, reinstateIndex: true).kind == .applied
                        }
                    }
                    return ProtectedRestoreExecution(
                        restoredSHA: sha,
                        snapshotOfPreviousState: GitRecoverySnapshot(
                            referenceName: currentSnapshot.referenceName,
                            commitSHA: currentSnapshot.commitSHA,
                            stashMessage: currentStash?.message
                        ),
                        previousStashReapplied: reapplied
                    )
                } catch {
                    if let currentStash {
                        throw VaultBridgeStrandedShelfError(underlying: error, stashMessage: currentStash.message)
                    }
                    throw error
                }
            }

            // The state just left becomes the new protected backup.
            recoveryByRepo[repoID] = outcome.snapshotOfPreviousState
            saveProtectedRecoveries()
            markRepositoryMutated(repoID: repoID)
            if let index = repoIndex(id: repoID) {
                repos[index].gitState.commitSHA = outcome.restoredSHA
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            if outcome.previousStashReapplied {
                setPullOutcome(repoID: repoID, kind: .restored, message: String(localized: "Protected phone backup restored. The files you just left are now the protected backup, so this can be undone."))
            } else {
                await loadConflictSession(repoID: repoID)
                setPullOutcome(repoID: repoID, kind: .mergeConflicts, message: String(localized: "Protected phone backup restored, but putting its sheltered edits back needs your choice for some notes."))
            }
        } catch let stranded as VaultBridgeStrandedShelfError {
            markRepositoryMutated(repoID: repoID)
            recordShelteredEdits(
                repoID: repoID,
                stashMessage: stranded.stashMessage,
                reason: "Kept safe during a backup restore"
            )
            detectChanges(repoID: repoID)
            let message = stranded.underlying.localizedDescription
                + " Your unsaved edits are sheltered and will be put back by the next sync."
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            showError(message: message, category: "recovery")
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: "Restore cancelled before any phone file changed.")
        } catch {
            showError(message: error.localizedDescription, category: "recovery")
        }
    }

    func revertCommit(repoID: UUID, oid: String, message: String = "") async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let gitService = gitRepositoryFactory(vaultURL(for: repoID))
        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Reverting commit...")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            DebugLogger.shared.info("revert", "Reverting commit", detail: "OID: \(oid)")
            let result = try await gitService.revertCommit(
                oid: oid,
                message: message,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail
            )
            markRepositoryMutated(repoID: repoID)

            switch result.kind {
            case .reverted:
                if let newCommitSHA = result.newCommitSHA,
                   let currentIndex = repoIndex(id: repoID) {
                    repos[currentIndex].gitState.commitSHA = newCommitSHA
                    repos[currentIndex].gitState.lastSyncDate = Date()
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                }
                syncProgress = String(localized: "Revert complete")
                DebugLogger.shared.info("revert", "Commit revert complete", detail: "new SHA: \(result.newCommitSHA ?? "nil")")
            case .conflicts:
                syncProgress = String(localized: "Revert has conflicts")
                DebugLogger.shared.warning("revert", "Commit revert produced conflicts", detail: "OID: \(oid)")
            }

            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "revert")
        }
    }

    func completeMerge(repoID: UUID, message: String = "", presentsErrors: Bool = true) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Combine phone and server changes")
            : message
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Finalizing merge...")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let result = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                return try await repository.completeMerge(
                    message: commitMessage,
                    authorName: repo.authorName,
                    authorEmail: repo.authorEmail
                )
            }

            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }
            setPullOutcome(
                repoID: repoID,
                kind: .merged,
                message: String(localized: "Phone and server changes are combined on this phone. Sync Now uploads them.")
            )
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
        } catch {
            await loadConflictSession(repoID: repoID)
            if presentsErrors {
                showError(message: error.localizedDescription)
            } else {
                DebugLogger.shared.error("merge", error.localizedDescription)
            }
            return
        }
        if shelteredEditsByRepo[repoID] != nil {
            await restoreShelteredEdits(repoID: repoID, presentsErrors: presentsErrors)
        }
    }

    func abortMerge(repoID: UUID) async {
        guard let _ = repoIndex(id: repoID), repo(id: repoID)?.isCloned == true else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Aborting merge...")

        var aborted = false
        do {
            try await gitService.abortMerge()
            aborted = true
            markRepositoryMutated(repoID: repoID)
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            setPullOutcome(repoID: repoID, kind: .diverged, message: String(localized: "Combine abandoned. Phone and server still differ; Sync Now will try again."))
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription)
        }

        isSyncing = false
        syncingRepoID = nil
        if aborted, shelteredEditsByRepo[repoID] != nil {
            await restoreShelteredEdits(repoID: repoID)
        }
    }

    func markRepositoryMutated(repoID: UUID) {
        repoMutationGeneration[repoID, default: 0] += 1
    }

    private func withCheckoutMutation<T>(repoID: UUID, operation: () async throws -> T) async rethrows -> T {
        markRepositoryMutated(repoID: repoID)
        defer { markRepositoryMutated(repoID: repoID) }
        return try await operation()
    }

    private func stagedStatusKind(from workTreeStatus: GitFileStatusKind) -> GitFileStatusKind {
        workTreeStatus == .untracked ? .added : workTreeStatus
    }

    private func unstagedStatusKind(from indexStatus: GitFileStatusKind) -> GitFileStatusKind {
        indexStatus == .added ? .untracked : indexStatus
    }

    private func optimisticallyStageStatusEntry(repoID: UUID, path: String) {
        guard var entries = statusEntriesByRepo[repoID],
              let entryIndex = entries.firstIndex(where: { $0.path == path }) else { return }

        let entry = entries[entryIndex]
        let indexStatus = entry.workTreeStatus.map(stagedStatusKind(from:)) ?? entry.indexStatus
        entries[entryIndex] = GitStatusEntry(
            path: entry.path,
            indexStatus: indexStatus,
            workTreeStatus: nil,
            oldPath: entry.oldPath
        )
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    private func optimisticallyStageAllStatusEntries(repoID: UUID) {
        guard let currentEntries = statusEntriesByRepo[repoID] else { return }
        let entries = currentEntries.map { entry in
            GitStatusEntry(
                path: entry.path,
                indexStatus: entry.workTreeStatus.map(stagedStatusKind(from:)) ?? entry.indexStatus,
                workTreeStatus: nil,
                oldPath: entry.oldPath
            )
        }
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    private func optimisticallyUnstageStatusEntry(repoID: UUID, path: String) {
        guard var entries = statusEntriesByRepo[repoID],
              let entryIndex = entries.firstIndex(where: { $0.path == path }) else { return }

        let entry = entries[entryIndex]
        let workTreeStatus: GitFileStatusKind?
        if entry.indexStatus == .added {
            workTreeStatus = .untracked
        } else {
            workTreeStatus = entry.workTreeStatus ?? entry.indexStatus.map(unstagedStatusKind(from:))
        }
        if let workTreeStatus {
            entries[entryIndex] = GitStatusEntry(
                path: entry.path,
                indexStatus: nil,
                workTreeStatus: workTreeStatus,
                oldPath: entry.oldPath
            )
        } else {
            entries.remove(at: entryIndex)
        }
        statusEntriesByRepo[repoID] = entries
        changeCounts[repoID] = entries.count
        diffByRepo[repoID] = .empty
    }

    func stageFile(repoID: UUID, path: String, oldPath: String? = nil) async {
        await stageFile(repoID: repoID, path: path, oldPath: oldPath, lfsAutoTrack: false, promptForLFS: true)
    }

    private func stageFile(
        repoID: UUID,
        path: String,
        oldPath: String?,
        lfsAutoTrack: Bool,
        promptForLFS: Bool
    ) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            if promptForLFS {
                let candidates = try await gitService.lfsAutoTrackingCandidates(paths: [path])
                if !candidates.isEmpty {
                    pendingLFSAutoTrackingConfirmation = LFSAutoTrackingConfirmationRequest(
                        repoID: repoID,
                        action: .stageFile(path: path, oldPath: oldPath),
                        candidates: candidates
                    )
                    return
                }
            }

            let startedAt = Date()
            try await gitService.stage(path: path, oldPath: oldPath, lfsAutoTrack: lfsAutoTrack)
            markRepositoryMutated(repoID: repoID)
            optimisticallyStageStatusEntry(repoID: repoID, path: path)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Stage file was slow",
                    detail: "\(path): \(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func stageAllChanges(repoID: UUID) async {
        await stageAllChanges(repoID: repoID, lfsAutoTrack: false, promptForLFS: true)
    }

    private func stageAllChanges(repoID: UUID, lfsAutoTrack: Bool, promptForLFS: Bool) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            if promptForLFS {
                // Only inspect currently changed files. Scanning the whole vault here
                // is expensive for media-heavy Obsidian repos and can make Stage All
                // feel frozen even when most large assets are clean.
                let candidatePaths = statusEntriesByRepo[repoID]?.map(\.path) ?? []
                let candidates = try await gitService.lfsAutoTrackingCandidates(paths: candidatePaths)
                if !candidates.isEmpty {
                    pendingLFSAutoTrackingConfirmation = LFSAutoTrackingConfirmationRequest(
                        repoID: repoID,
                        action: .stageAll,
                        candidates: candidates
                    )
                    return
                }
            }

            let startedAt = Date()
            try await gitService.stageAll(lfsAutoTrack: lfsAutoTrack)
            markRepositoryMutated(repoID: repoID)
            optimisticallyStageAllStatusEntries(repoID: repoID)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Stage all was slow",
                    detail: "\(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func confirmPendingLFSAutoTracking(useLFS: Bool) async {
        guard let request = pendingLFSAutoTrackingConfirmation else { return }
        pendingLFSAutoTrackingConfirmation = nil
        guard useLFS else { return }

        switch request.action {
        case .stageFile(let path, let oldPath):
            await stageFile(repoID: request.repoID, path: path, oldPath: oldPath, lfsAutoTrack: true, promptForLFS: false)
        case .stageAll:
            await stageAllChanges(repoID: request.repoID, lfsAutoTrack: true, promptForLFS: false)
        }
    }

    func unstageFile(repoID: UUID, path: String, oldPath: String? = nil) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        do {
            let startedAt = Date()
            try await gitService.unstage(path: path, oldPath: oldPath)
            markRepositoryMutated(repoID: repoID)
            optimisticallyUnstageStatusEntry(repoID: repoID, path: path)
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 2 {
                DebugLogger.shared.info(
                    "stage",
                    "Unstage file was slow",
                    detail: "\(path): \(String(format: "%.1f", elapsed))s"
                )
            }
            detectChanges(repoID: repoID)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func discardAllFileChanges(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription, category: "revert")
            return
        }

        do {
            DebugLogger.shared.info("revert", "Reverting all file changes")
            try await withCheckoutMutation(repoID: repoID) {
                try await gitService.discardAllChanges()
            }
            detectChanges(repoID: repoID)
            DebugLogger.shared.info("revert", "Revert all complete")
        } catch {
            showError(message: error.localizedDescription, category: "revert")
        }
    }

    func discardFileChanges(repoID: UUID, path: String) async {
        guard let repo = repo(id: repoID), repo.isCloned else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription, category: "revert")
            return
        }

        do {
            DebugLogger.shared.info("revert", "Reverting file changes", detail: path)
            try await withCheckoutMutation(repoID: repoID) {
                try await gitService.discardChanges(path: path)
            }
            detectChanges(repoID: repoID)
            DebugLogger.shared.info("revert", "File revert complete", detail: path)
        } catch {
            showError(message: error.localizedDescription, category: "revert")
        }
    }

    // MARK: - Git Operations (libgit2)

    func clone(repoID: UUID) async {
        guard let idx = repoIndex(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Preparing to clone...")

        if isDemoMode {
            syncProgress = String(localized: "Cloning repository...")
            try? await Task.sleep(for: .seconds(1.5))
            syncProgress = String(localized: "Clone complete! (%lld files)", defaultValue: "Clone complete! (4 files)")
            try? await Task.sleep(for: .seconds(1))
            isSyncing = false
            syncingRepoID = nil
            return
        }

        do {
            let fm = FileManager.default

            // If the user configured a default save location after this repo
            // was first added, adopt it now so the (re-)clone lands in the
            // chosen folder instead of the in-app Documents directory.
            if repos[idx].customVaultBookmarkData == nil,
               let defaultBookmark = defaultSaveLocationBookmarkData {
                let staleVaultDir = repos[idx].defaultVaultURL
                repos[idx].customVaultBookmarkData = defaultBookmark
                repos[idx].customLocationIsParent = true
                saveRepos()
                resolveVaultBookmark(for: repoID)
                if fm.fileExists(atPath: staleVaultDir.path) {
                    _ = try? Self.moveAsideExistingVault(at: staleVaultDir)
                }
            }

            let repo = repos[idx]
            let vaultDir = vaultURL(for: repoID)

            // git clone needs a clean target, but never delete an existing
            // folder outright: a stale "not cloned" state or a corrupted
            // repository funnels users here while the folder may still hold
            // the only copy of unpushed work. Move it aside instead so the
            // contents stay recoverable from the Files app.
            if fm.fileExists(atPath: vaultDir.path) {
                try Self.moveAsideExistingVault(at: vaultDir)
            }

            // Ensure parent directory exists (git clone creates the target dir itself)
            let parentDir = vaultDir.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Build a clone-friendly URL. Preserve custom remotes exactly;
            // only expand the historical GitHub owner/repo shorthand.
            let cloneURL = GitRemoteURL.cloneURLString(from: repo.repoURL) ?? repo.repoURL

            let gitService = gitRepositoryFactory(vaultDir)

            syncProgress = String(localized: "Cloning repository...")
            DebugLogger.shared.info("clone", "Starting clone", detail: cloneURL)
            let result = try await gitService.clone(remoteURL: cloneURL, pat: authPayload(for: repo))

            // Update only the still-present repository. The main actor may
            // process a deletion or settings edit while clone is suspended.
            if let currentIndex = repoIndex(id: repoID) {
                if repos[currentIndex].branch.isEmpty {
                    repos[currentIndex].branch = result.branch
                }
                repos[currentIndex].gitState = GitState(
                    commitSHA: result.commitSHA,
                    treeSHA: "",
                    branch: result.branch,
                    blobSHAs: [:],
                    lastSyncDate: Date()
                )
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            syncProgress = String(localized: "Clone complete! (\(result.fileCount) files)")
            DebugLogger.shared.info("clone", "Clone complete", detail: "\(result.fileCount) files, branch: \(result.branch)")
            if let lfsWarning = result.lfsWarning {
                showError(message: lfsWarning, category: "lfs")
            }


        } catch {
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .clone) {
                showError(message: error.localizedDescription, category: "clone")
            }
        }

        try? await Task.sleep(for: .seconds(1))
        isSyncing = false
        syncingRepoID = nil
    }

    @discardableResult
    func pull(repoID: UUID, showsProgressDelay: Bool = true) async -> Bool {
        // Preserve the legacy foreground contract: a completed classification
        // (including a safe attention state) returns true so existing sheets can
        // dismiss. Headless callers consume the precise `pullOnly` result.
        switch await pullOnly(repoID: repoID, showsProgressDelay: showsProgressDelay) {
        case .updated, .upToDate, .blockedByLocalChanges, .diverged, .remoteBranchMissing:
            return true
        case .wrongBranch, .authenticationOrTrustRequired, .unavailable, .failed, .cancelled:
            return false
        }
    }

    /// UI-independent, typed, pull-only execution seam for foreground, App
    /// Intents, and future Premium triggers.
    @discardableResult
    func pullOnly(repoID: UUID, showsProgressDelay: Bool = true) async -> RepositoryPullResult {
        guard let idx = repoIndex(id: repoID) else {
            let message = String(localized: "Repository not found")
            showError(message: message)
            return .unavailable(message: message)
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Checking for updates...")
        pullOutcomeByRepo.removeValue(forKey: repoID)
        defer {
            isSyncing = false
            syncingRepoID = nil
        }

        if isDemoMode {
            if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
            syncProgress = String(localized: "Already up to date!")
            guard let currentIndex = repoIndex(id: repoID) else {
                return .unavailable(message: String(localized: "Repository not found"))
            }
            repos[currentIndex].gitState.lastSyncDate = Date()
            saveRepos()
            return .upToDate(
                branch: repos[currentIndex].gitState.branch,
                commitSHA: repos[currentIndex].gitState.commitSHA
            )
        }

        let repo = repos[idx]
        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)
        DebugLogger.shared.info("pull", "Starting pull", detail: "branch: \(repo.branch)")
        // The runner may fast-forward the checkout. Invalidate any status scan
        // that began before fetch/checkout starts; successful updates advance it
        // again below after the working copy is coherent.
        markRepositoryMutated(repoID: repoID)
        let result = await RepositoryPullRunner().run(
            repository: gitService,
            credentials: authPayload(for: repo)
        )

        switch result {
        case .updated(_, let commitSHA):
            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = commitSHA
                repos[currentIndex].gitState.lastSyncDate = Date()
                repos[currentIndex].gitState.remoteCommitSHA = commitSHA
                repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            syncProgress = String(localized: "Pull complete!")
            setPullOutcome(repoID: repoID, kind: .fastForwarded, message: String(localized: "Pulled latest changes (fast-forward)"))
            requestReviewIfNeeded()

        case .upToDate(_, let commitSHA):
            syncProgress = String(localized: "Already up to date!")
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.remoteCommitSHA = commitSHA
                repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }
            setPullOutcome(repoID: repoID, kind: .upToDate, message: String(localized: "Already up to date"))

        case .blockedByLocalChanges:
            syncProgress = String(localized: "Pull blocked by local changes")
            setPullOutcome(repoID: repoID, kind: .blockedByLocalChanges, message: String(localized: "This phone has edits that are not saved in a restore point yet. Tap Save on This iPhone, then bring in server updates."))

        case .diverged:
            syncProgress = String(localized: "Both sides have new work")
            setPullOutcome(repoID: repoID, kind: .diverged, message: String(localized: "This phone and the server both have saved work. Sync Now combines them."))

        case .remoteBranchMissing(let branch):
            syncProgress = String(localized: "Remote branch missing")
            setPullOutcome(repoID: repoID, kind: .remoteBranchMissing, message: String(localized: "Remote branch '\(branch)' was not found."))

        case .wrongBranch(let expected, let actual):
            let message = String(localized: "Expected branch '\(expected)', but '\(actual)' is checked out.")
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            showError(message: message, category: "pull")

        case .authenticationOrTrustRequired(let message, let trustError):
            if let trustError {
                _ = handleSSHHostKeyTrustIfNeeded(
                    LocalGitError.sshHostKeyTrustRequired(trustError),
                    repoID: repoID,
                    operation: .pull
                )
            }
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            if trustError == nil { showError(message: message, category: "pull") }

        case .unavailable(let message), .failed(let message):
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            showError(message: message, category: "pull")

        case .cancelled:
            // SwiftUI cancels refresh tasks when the gesture/view goes away.
            // That is expected control flow, not an error worth alarming the
            // user about.
            syncProgress = String(localized: "Refresh cancelled")
            setPullOutcome(repoID: repoID, kind: .cancelled, message: String(localized: "Check cancelled"))
        }

        // The mutation generation was advanced before the runner began. Always
        // schedule a fresh scan so blocked, failed, and no-op results cannot
        // leave an older in-flight scan as the last published status.
        detectChanges(repoID: repoID)
        if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
        return result
    }

    @discardableResult
    func pullWithRebase(
        repoID: UUID,
        showsProgressDelay: Bool = true,
        presentsErrors: Bool = true,
        refreshStatus: Bool = true
    ) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Checking for updates...")
        defer { isSyncing = false; syncingRepoID = nil }

        if isDemoMode {
            if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }
            return true
        }
        pullOutcomeByRepo.removeValue(forKey: repoID)
        let credentials = authPayload(for: repo)
        do {
            let serialized = try serializedRepository(repoID: repoID)
            let execution = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let plan = try await repository.pullPlan(pat: credentials)
                switch plan.action {
                case .fastForward:
                    return RebasePullExecution(plan: plan, result: try await repository.pullFastForward(branch: plan.branch, pat: credentials))
                case .diverged:
                    return RebasePullExecution(plan: plan, result: try await repository.pullRebase(
                        branch: plan.branch, pat: credentials,
                        authorName: repo.authorName, authorEmail: repo.authorEmail))
                case .upToDate, .blockedByLocalChanges, .remoteBranchMissing:
                    return RebasePullExecution(plan: plan, result: nil)
                }
            }
            let plan = execution.plan
            if let currentIndex = repoIndex(id: repoID) {
                if !plan.remoteCommitSHA.isEmpty {
                    repos[currentIndex].gitState.remoteCommitSHA = plan.remoteCommitSHA
                }
                repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }
            switch plan.action {
            case .upToDate:
                syncStateByRepo[repoID] = .upToDate
                setPullOutcome(repoID: repoID, kind: .upToDate, message: String(localized: "Already up to date"))
                return true
            case .blockedByLocalChanges:
                setPullOutcome(repoID: repoID, kind: .blockedByLocalChanges, message: String(localized: "Some phone edits are not saved yet. Create a phone restore point before combining histories."))
                return false
            case .remoteBranchMissing:
                setPullOutcome(repoID: repoID, kind: .remoteBranchMissing, message: String(localized: "Remote branch '\(plan.branch)' was not found."))
                return false
            case .fastForward, .diverged:
                guard let result = execution.result else { return false }
                markRepositoryMutated(repoID: repoID)
                if result.updated, let currentIndex = repoIndex(id: repoID) {
                    repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                    repos[currentIndex].gitState.lastSyncDate = Date()
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                }
                setPullOutcome(
                    repoID: repoID,
                    kind: result.updated ? (plan.action == .diverged ? .rebased : .fastForwarded) : .upToDate,
                    message: result.updated
                        ? (plan.action == .diverged
                            ? String(localized: "Rebased local commits onto origin/\(plan.branch)")
                            : String(localized: "Pulled latest changes (fast-forward)"))
                        : String(localized: "Already up to date")
                )
                if result.updated && plan.action == .fastForward {
                    changeCounts[repoID] = 0
                    statusEntriesByRepo[repoID] = []
                    syncStateByRepo[repoID] = .upToDate
                }
                if refreshStatus {
                    detectChanges(repoID: repoID)
                    await loadBranches(repoID: repoID)
                }
                requestReviewIfNeeded()
                if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
                return true
            }
        } catch LocalGitError.rebaseConflictsDetected {
            markRepositoryMutated(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            if refreshStatus { detectChanges(repoID: repoID) }
            setPullOutcome(repoID: repoID, kind: .rebaseConflicts, message: String(localized: "Rebase has conflicts — resolve them, then continue rebase"))
        } catch is CancellationError {
            // A cancelled automatic run (e.g. abandoned pull-to-refresh) is not
            // a Git failure; never surface it as a modal error.
            setPullOutcome(repoID: repoID, kind: .cancelled, message: String(localized: "Sync was cancelled"))
        } catch {
            setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
            if presentsErrors {
                showError(message: error.localizedDescription, category: "rebase")
            } else {
                DebugLogger.shared.error("rebase", error.localizedDescription)
            }
        }
        if showsProgressDelay { try? await Task.sleep(for: .seconds(1)) }
        return false
    }

    /// The reconcile step of the automatic workflow. Fetches, then brings the
    /// server's work onto this phone: a fast-forward when only the server
    /// moved, a merge commit when both sides moved. A merge never rewrites the
    /// phone's commits, so the commit ID the user was shown stays valid.
    /// Returns true when the vault is ready to upload.
    @discardableResult
    func pullWithMerge(
        repoID: UUID,
        presentsErrors: Bool = true,
        refreshStatus: Bool = true
    ) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Comparing phone and server…")
        defer { isSyncing = false; syncingRepoID = nil }

        if isDemoMode {
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }
            setPullOutcome(repoID: repoID, kind: .upToDate, message: String(localized: "Up to date with the server"))
            return true
        }
        pullOutcomeByRepo.removeValue(forKey: repoID)
        let credentials = authPayload(for: repo)
        let authorName = repo.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorEmail = repo.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let serialized = try serializedRepository(repoID: repoID)
            let execution: MergePullExecution = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                let plan = try await repository.pullPlan(pat: credentials)
                switch plan.action {
                case .fastForward:
                    let result = try await repository.pullFastForward(branch: plan.branch, pat: credentials)
                    return MergePullExecution(plan: plan, fastForward: result, merge: nil)
                case .diverged:
                    guard !authorName.isEmpty, !authorEmail.isEmpty else {
                        throw LocalGitError.invalidAuthorIdentity("Set a Git author name and email for \(repo.displayName) before combining phone and server changes.")
                    }
                    let merge = try await repository.mergeBranch(
                        name: "origin/\(plan.branch)",
                        authorName: authorName,
                        authorEmail: authorEmail
                    )
                    return MergePullExecution(plan: plan, fastForward: nil, merge: merge)
                case .upToDate, .blockedByLocalChanges, .remoteBranchMissing:
                    return MergePullExecution(plan: plan, fastForward: nil, merge: nil)
                }
            }

            let plan = execution.plan
            if let currentIndex = repoIndex(id: repoID) {
                if !plan.remoteCommitSHA.isEmpty {
                    repos[currentIndex].gitState.remoteCommitSHA = plan.remoteCommitSHA
                }
                repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }

            switch plan.action {
            case .upToDate:
                syncStateByRepo[repoID] = plan.aheadBy > 0 ? .ahead : .upToDate
                setPullOutcome(
                    repoID: repoID,
                    kind: .upToDate,
                    message: plan.aheadBy > 0
                        ? String(localized: "Server checked. This phone has saved work to upload.")
                        : String(localized: "Up to date with the server")
                )
                return true
            case .blockedByLocalChanges:
                setPullOutcome(repoID: repoID, kind: .blockedByLocalChanges, message: String(localized: "Some notes were still being written. Sync again in a moment."))
                return false
            case .remoteBranchMissing:
                setPullOutcome(repoID: repoID, kind: .remoteBranchMissing, message: String(localized: "The server has no '\(plan.branch)' branch yet. Uploading will create it."))
                return true
            case .fastForward:
                guard let result = execution.fastForward else { return false }
                markRepositoryMutated(repoID: repoID)
                if result.updated, let currentIndex = repoIndex(id: repoID) {
                    repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                    changeCounts[repoID] = 0
                    statusEntriesByRepo[repoID] = []
                    syncStateByRepo[repoID] = .upToDate
                }
                setPullOutcome(
                    repoID: repoID,
                    kind: result.updated ? .fastForwarded : .upToDate,
                    message: result.updated
                        ? String(localized: "Newer server notes were brought onto this phone.")
                        : String(localized: "Up to date with the server")
                )
                if refreshStatus {
                    detectChanges(repoID: repoID)
                    await loadBranches(repoID: repoID)
                }
                return true
            case .diverged:
                guard let merge = execution.merge else { return false }
                markRepositoryMutated(repoID: repoID)
                if let currentIndex = repoIndex(id: repoID), !merge.newCommitSHA.isEmpty {
                    repos[currentIndex].gitState.commitSHA = merge.newCommitSHA
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                }
                syncStateByRepo[repoID] = merge.kind == .upToDate ? .upToDate : .ahead
                setPullOutcome(
                    repoID: repoID,
                    kind: merge.kind == .upToDate ? .upToDate : .merged,
                    message: merge.kind == .upToDate
                        ? String(localized: "Up to date with the server")
                        : String(localized: "Phone and server changes were combined on this phone.")
                )
                if refreshStatus {
                    detectChanges(repoID: repoID)
                    await loadBranches(repoID: repoID)
                }
                return true
            }
        } catch LocalGitError.mergeConflictsDetected {
            markRepositoryMutated(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            if refreshStatus { detectChanges(repoID: repoID) }
            let count = conflictSessionByRepo[repoID]?.unmergedPaths.count ?? 0
            setPullOutcome(repoID: repoID, kind: .mergeConflicts, message: Self.conflictChoiceMessage(count: count))
            return false
        } catch LocalGitError.mergeBlockedByLocalChanges {
            setPullOutcome(repoID: repoID, kind: .blockedByLocalChanges, message: String(localized: "Some notes were still being written. Sync again in a moment."))
            return false
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: String(localized: "Sync was cancelled"))
            return false
        } catch {
            setPullOutcome(repoID: repoID, kind: .failed, message: error.localizedDescription)
            if presentsErrors {
                showError(message: error.localizedDescription, category: "merge")
            } else {
                DebugLogger.shared.error("merge", error.localizedDescription)
            }
            return false
        }
    }

    func continueRebase(repoID: UUID) async {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return }
        let gitService = gitRepositoryFactory(vaultURL(for: repoID))
        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Continuing rebase...")
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let result = try await withCheckoutMutation(repoID: repoID) {
                try await gitService.continueRebase(
                    pat: authPayload(for: repo),
                    authorName: repo.authorName,
                    authorEmail: repo.authorEmail
                )
            }
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = result.newCommitSHA
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }
            detectChanges(repoID: repoID)
            await loadBranches(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            syncProgress = String(localized: "Rebase complete!")
            setPullOutcome(
                repoID: repoID,
                kind: .rebased,
                message: String(localized: "Rebase completed successfully")
            )
        } catch LocalGitError.rebaseConflictsDetected {
            await loadConflictSession(repoID: repoID)
            detectChanges(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .rebaseConflicts,
                message: String(localized: "Rebase has more conflicts — resolve them, then continue rebase")
            )
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "rebase")
        }
    }

    func abortRebase(repoID: UUID) async {
        guard let _ = repoIndex(id: repoID), repo(id: repoID)?.isCloned == true else { return }
        if isDemoMode { return }

        let vaultDir = vaultURL(for: repoID)
        let gitService = gitRepositoryFactory(vaultDir)

        guard gitService.hasGitDirectory else {
            showError(message: LocalGitError.notCloned.localizedDescription)
            return
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Aborting rebase...")

        do {
            try await withCheckoutMutation(repoID: repoID) {
                try await gitService.abortRebase()
            }
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)
            await loadConflictSession(repoID: repoID)
            setPullOutcome(
                repoID: repoID,
                kind: .diverged,
                message: String(localized: "Rebase aborted. Local and remote still diverge.")
            )
        } catch {
            await loadConflictSession(repoID: repoID)
            showError(message: error.localizedDescription, category: "rebase")
        }

        isSyncing = false
        syncingRepoID = nil
    }

    @discardableResult
    func pushCurrentBranch(
        repoID: UUID,
        presentsErrors: Bool = true,
        refreshStatus: Bool = true,
        preflightFetch: Bool = true
    ) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned else { return false }
        if isDemoMode {
            syncProgress = String(localized: "Push complete!")
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
            }
            syncStateByRepo[repoID] = .upToDate
            return true
        }

        let credentials = authPayload(for: repo)
        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Uploading saved changes…")
        pushErrorByRepo.removeValue(forKey: repoID)
        defer { isSyncing = false; syncingRepoID = nil }

        do {
            let serialized = try serializedRepository(repoID: repoID)
            let execution: PushExecution = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                if preflightFetch {
                    // Uploading blind turned "not uploaded yet" into an endless
                    // loop: the server had moved, the push was rejected with a
                    // Git message, and nothing re-classified the vault. Look
                    // first and let the sync workflow combine.
                    let plan = try await repository.pullPlan(pat: credentials)
                    switch plan.action {
                    case .fastForward, .diverged, .blockedByLocalChanges:
                        return .serverMoved(plan)
                    case .upToDate, .remoteBranchMissing:
                        break
                    }
                }
                try await repository.pushCurrentBranch(pat: credentials)
                return .pushed(try? await repository.repoInfo())
            }

            switch execution {
            case .serverMoved(let plan):
                if let currentIndex = repoIndex(id: repoID) {
                    if !plan.remoteCommitSHA.isEmpty {
                        repos[currentIndex].gitState.remoteCommitSHA = plan.remoteCommitSHA
                    }
                    repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                    saveRepos()
                }
                syncStateByRepo[repoID] = plan.aheadBy > 0 ? .diverged : .behind
                let message = plan.aheadBy > 0
                    ? String(localized: "The server has newer notes and this phone has saved work. Sync Now combines them, then uploads.")
                    : String(localized: "The server has newer notes. Sync Now brings them in first.")
                syncProgress = message
                setPullOutcome(repoID: repoID, kind: .diverged, message: message)
                if refreshStatus { detectChanges(repoID: repoID) }
                return false

            case .pushed(let info):
                if let currentIndex = repoIndex(id: repoID) {
                    if let info {
                        repos[currentIndex].gitState.branch = info.branch
                        repos[currentIndex].gitState.commitSHA = info.commitSHA
                        changeCounts[repoID] = info.changeCount
                        statusEntriesByRepo[repoID] = info.statusEntries
                        syncStateByRepo[repoID] = info.syncState
                        repos[currentIndex].gitState.remoteCommitSHA = info.commitSHA
                        repos[currentIndex].gitState.lastRemoteCheckDate = Date()
                    }
                    repos[currentIndex].gitState.lastSyncDate = Date()
                    saveRepos()
                    clearCommitHistoryCache(for: repoID)
                }
                if refreshStatus {
                    detectChanges(repoID: repoID)
                    await loadBranches(repoID: repoID)
                }
                let verifiedSHA = info?.commitSHA ?? repo.gitState.commitSHA
                syncProgress = "Uploaded and verified on the server at \(String(verifiedSHA.prefix(7))). Phone and server match."
                setPullOutcome(repoID: repoID, kind: .upToDate, message: syncProgress)
                requestReviewIfNeeded()
                return true
            }
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: String(localized: "Upload cancelled"))
            return false
        } catch {
            let isLFSRepairEligible: Bool
            if case LocalGitError.lfsLargeBlobsNotTracked = error {
                isLFSRepairEligible = true
            } else {
                isLFSRepairEligible = false
            }
            let message = Self.plainPushFailureMessage(for: error)
            pushErrorByRepo[repoID] = PushErrorState(
                message: message,
                isLFSRepairEligible: isLFSRepairEligible,
                date: Date()
            )
            setPullOutcome(repoID: repoID, kind: .failed, message: message)
            if refreshStatus { detectChanges(repoID: repoID) }
            // The SSH host-key prompt stays active even for automatic runs —
            // it is an actionable decision, not an error report.
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pushCurrentBranch) {
                if presentsErrors {
                    showError(message: message, category: "push")
                } else {
                    DebugLogger.shared.error("push", message)
                }
            }
            return false
        }
    }

    /// A rejected non-fast-forward push is the one Git error every vault user
    /// eventually meets. Say what happened and what the app will do about it.
    nonisolated static func plainPushFailureMessage(for error: Error) -> String {
        if case LocalGitError.pushFailed(let detail) = error {
            let lowered = detail.lowercased()
            if lowered.contains("not present locally")
                || lowered.contains("fast-forward")
                || lowered.contains("fast forward")
                || lowered.contains("fetch first")
                || lowered.contains("non-fast") {
                return String(localized: "The server changed while uploading. Sync Now combines the new server notes with this phone's work, then uploads.")
            }
        }
        return error.localizedDescription
    }

    /// Explicit repair for large files that were committed as ordinary blobs
    /// in strictly-unpushed commits: rewrites only the local-only range with
    /// LFS pointers (backup ref first, authors/messages preserved), then runs
    /// the normal validate → LFS upload → non-force push pipeline.
    @discardableResult
    func repairLargeFilesAndPush(repoID: UUID) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return false }
        guard !isSyncing else { return false }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Repairing large files for Git LFS…")

        let repairSucceeded: Bool
        do {
            let credentials = authPayload(for: repo)
            let serialized = try serializedRepository(repoID: repoID)
            let result = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                return try await repository.repairUnpushedLargeBlobs(pat: credentials)
            }

            markRepositoryMutated(repoID: repoID)
            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = result.newHeadSHA
                saveRepos()
            }
            clearCommitHistoryCache(for: repoID)
            detectChanges(repoID: repoID)

            switch result.outcome {
            case .repaired:
                DebugLogger.shared.info(
                    "lfs",
                    "Rewrote unpushed commits to use Git LFS pointers",
                    detail: "commits: \(result.rewrittenCommitCount), files: \(result.convertedPaths.count), backup: \(result.backupRefName ?? "-")"
                )
                syncProgress = String(localized: "Repair complete — pushing…")
            case .nothingToRepair:
                syncProgress = String(localized: "No unpushed large files needed repair — pushing…")
            }
            repairSucceeded = true
        } catch {
            showError(message: error.localizedDescription, category: "lfs")
            repairSucceeded = false
        }

        isSyncing = false
        syncingRepoID = nil
        guard repairSucceeded else { return false }
        return await pushCurrentBranch(repoID: repoID)
    }

    /// Checks every current Git LFS attachment against the server and uploads
    /// only missing payloads. This changes neither files nor Git history.
    @discardableResult
    func repairMissingLFSObjects(repoID: UUID) async -> Bool {
        guard let repo = repo(id: repoID), repo.isCloned, !isDemoMode else { return false }
        guard !isSyncing else { return false }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Checking attachment backups…")
        defer {
            isSyncing = false
            syncingRepoID = nil
        }

        do {
            let credentials = authPayload(for: repo)
            let serialized = try serializedRepository(repoID: repoID)
            let result = try await serialized.withLease { repository in
                guard repository.hasGitDirectory else { throw LocalGitError.notCloned }
                return try await repository.backfillLFSObjects(pat: credentials)
            }

            let message: String
            if result.referencedCount == 0 {
                message = String(localized: "No Git LFS attachments are referenced by this phone. No files or commits changed.")
            } else if result.uploadedCount == 0 {
                message = String(localized: "Verified all \(result.referencedCount) attachment backups on the server. No files or commits changed.")
            } else {
                message = String(localized: "Repaired and verified \(result.uploadedCount) missing attachment backups on the server. No files or commits changed.")
            }
            syncProgress = message
            setPullOutcome(repoID: repoID, kind: .saved, message: message)
            DebugLogger.shared.info(
                "lfs",
                "Verified current Git LFS attachment backups",
                detail: "referenced=\(result.referencedCount), uploaded=\(result.uploadedCount)"
            )
            return true
        } catch is CancellationError {
            setPullOutcome(repoID: repoID, kind: .cancelled, message: "Attachment backup repair cancelled")
            return false
        } catch {
            showError(message: error.localizedDescription, category: "lfs")
            return false
        }
    }

    @discardableResult
    func push(repoID: UUID, message: String) async -> Bool {
        guard let repo = repo(id: repoID) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        // If we're in the middle of a merge, "Commit & Push" really means
        // "complete the merge and push the merge commit". commitAndPush
        // would otherwise fail with "nothing to commit" when the conflict
        // resolution left the tree identical to HEAD — and even when it
        // didn't, we'd lose the two-parent merge topology.
        if let session = conflictSessionByRepo[repoID] {
            if session.kind == .merge {
                await completeMerge(repoID: repoID, message: message)
                return conflictSessionByRepo[repoID]?.isActive == false
                    && pullOutcomeByRepo[repoID]?.kind != .failed
            }
            if session.kind == .rebase {
                await continueRebase(repoID: repoID)
                return conflictSessionByRepo[repoID]?.isActive == false
            }
        }

        isSyncing = true
        syncingRepoID = repoID
        syncProgress = String(localized: "Preparing changes...")
        defer { isSyncing = false; syncingRepoID = nil }

        if isDemoMode {
            syncProgress = String(localized: "Committing and pushing...")
            try? await Task.sleep(for: .seconds(1.5))
            guard let currentIndex = repoIndex(id: repoID) else { return false }
            repos[currentIndex].gitState.commitSHA = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(40)
                .lowercased()
            repos[currentIndex].gitState.lastSyncDate = Date()
            saveRepos()
            changeCounts[repoID] = 0
            syncProgress = String(localized: "Push complete!")
            try? await Task.sleep(for: .seconds(1))
            return true
        }

        do {
            let gitService = gitRepositoryFactory(vaultURL(for: repoID))
            guard gitService.hasGitDirectory else { throw LocalGitError.notCloned }
            let commitMsg = message.isEmpty ? String(localized: "Update from GitSync.md") : message

            syncProgress = String(localized: "Committing and pushing...")
            DebugLogger.shared.info("push", "Starting commit & push", detail: "message: \(commitMsg)")
            let result = try await gitService.commitAndPush(
                message: commitMsg,
                authorName: repo.authorName,
                authorEmail: repo.authorEmail,
                pat: authPayload(for: repo)
            )

            if let currentIndex = repoIndex(id: repoID) {
                repos[currentIndex].gitState.commitSHA = result.commitSHA
                repos[currentIndex].gitState.lastSyncDate = Date()
                saveRepos()
                clearCommitHistoryCache(for: repoID)
            }
            detectChanges(repoID: repoID)
            syncProgress = String(localized: "Push complete!")
            DebugLogger.shared.info("push", "Push complete", detail: "SHA: \(result.commitSHA)")
            requestReviewIfNeeded()

            try? await Task.sleep(for: .seconds(1))
            return true
        } catch {
            if !handleSSHHostKeyTrustIfNeeded(error, repoID: repoID, operation: .pushCommit(message: message)) {
                showError(message: error.localizedDescription, category: "push")
            }
        }

        try? await Task.sleep(for: .seconds(1))
        return false
    }

    // MARK: - Review Prompt

    private func requestReviewIfNeeded() {
        let reviewKey = "hasRequestedReview"
        if !UserDefaults.standard.bool(forKey: reviewKey) {
            UserDefaults.standard.set(true, forKey: reviewKey)
            shouldRequestReview = true
        }
    }

    // MARK: - Repo Management

    func addRepo(_ config: RepoConfig) {
        var config = config
        if config.gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           config.authMethod == .gitHubPAT,
           GitRemoteURL.parse(config.repoURL)?.isGitHub == true,
           !activeGitHubAccountLogin.isEmpty {
            config.gitHubAccountLogin = activeGitHubAccountLogin
        }
        repos.append(config)
        saveRepos()
        resolveVaultBookmark(for: config.id)
    }

    /// Add a repository that already exists on the local filesystem.
    /// Reads git metadata from the `.git` directory and creates a RepoConfig
    /// that's immediately in "cloned" state — no network clone needed.
    func addLocalRepo(
        url: URL,
        bookmarkData: Data,
        authorName: String,
        authorEmail: String
    ) async {
        // Resolve the bookmark and start security-scoped access
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            showError(message: String(localized: "Could not resolve folder bookmark."))
            return
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            showError(message: String(localized: "Could not access the selected folder."))
            return
        }

        let gitService = gitRepositoryFactory(resolvedURL)

        guard gitService.hasGitDirectory else {
            resolvedURL.stopAccessingSecurityScopedResource()
            showError(message: String(localized: "No .git directory found. Please select a folder that contains a git repository."))
            return
        }

        do {
            let info = try await gitService.repoInfo()

            // Try to read the remote URL from the git config
            let remoteURL = Self.readGitRemoteURL(at: resolvedURL) ?? ""

            let remoteInfo = GitRemoteURL.parse(remoteURL)
            let config = RepoConfig(
                repoURL: remoteURL,
                branch: info.branch,
                authorName: authorName,
                authorEmail: authorEmail,
                vaultFolderName: resolvedURL.lastPathComponent,
                customVaultBookmarkData: bookmarkData,
                authMethod: remoteInfo?.isGitHub == true && remoteInfo?.isSSH == false && isSignedIn ? .gitHubPAT : GitAuthMethod.none,
                authUsername: remoteInfo?.username ?? "",
                gitHubAccountLogin: remoteInfo?.isGitHub == true && remoteInfo?.isSSH == false && isSignedIn ? activeGitHubAccountLogin : nil,
                gitState: GitState(
                    commitSHA: info.commitSHA,
                    treeSHA: "",
                    branch: info.branch,
                    blobSHAs: [:],
                    lastSyncDate: Date()
                )
            )

            // Track resolved URL and security scope
            resolvedCustomURLs[config.id] = resolvedURL
            accessingSecurityScope.insert(config.id)

            repos.append(config)
            saveRepos()
            detectChanges(repoID: config.id)
        } catch {
            resolvedURL.stopAccessingSecurityScopedResource()
            showError(message: String(localized: "Failed to read repository info: \(error.localizedDescription)"))
        }
    }

    /// Read the `origin` remote URL from a git repository's config.
    private static func readGitRemoteURL(at repoURL: URL) -> String? {
        let configURL = repoURL.appendingPathComponent(".git/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        // Simple parser: find [remote "origin"] section, then the url = ... line
        let lines = contents.components(separatedBy: .newlines)
        var inOriginSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[remote \"origin\"]") {
                inOriginSection = true
                continue
            }
            if trimmed.hasPrefix("[") {
                inOriginSection = false
                continue
            }
            if inOriginSection && trimmed.hasPrefix("url") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    func removeRepo(id: UUID, deleteLocalFiles: Bool = false) {
        guard let repo = repo(id: id) else { return }
        if repo.assist.channel != nil { assistRepositoryRemovalHandler?(repo) }
        let vaultDir = vaultURL(for: id)

        // Existing local repositories are user-owned folders that may also be
        // managed by another app. Removing GitSync.md's bookmark must never
        // delete those files.
        if deleteLocalFiles && repo.isGitSyncManagedStorage {
            try? FileManager.default.removeItem(at: vaultDir)
        }

        clearCustomLocation(for: id)
        clearRemoteCredentials(for: id)
        clearCachedRepoState(for: id)
        repos.removeAll { $0.id == id }
        saveRepos()
    }

    private func clearCachedRepoState(for repoID: UUID) {
        changeCounts.removeValue(forKey: repoID)
        statusEntriesByRepo.removeValue(forKey: repoID)
        syncStateByRepo.removeValue(forKey: repoID)
        pullOutcomeByRepo.removeValue(forKey: repoID)
        pushErrorByRepo.removeValue(forKey: repoID)
        diffByRepo.removeValue(forKey: repoID)
        branchesByRepo.removeValue(forKey: repoID)
        conflictSessionByRepo.removeValue(forKey: repoID)
        commitHistoryByRepo.removeValue(forKey: repoID)
        commitHistoryHasMoreByRepo.removeValue(forKey: repoID)
        commitDetailByRepo.removeValue(forKey: repoID)
        stashesByRepo.removeValue(forKey: repoID)
        tagsByRepo.removeValue(forKey: repoID)
    }

    func updateRepo(id: UUID, mutate: (inout RepoConfig) -> Void) {
        guard let idx = repoIndex(id: id) else { return }
        let oldRegistration = (repos[idx].assist.enabled, repos[idx].assist.channel)
        mutate(&repos[idx])
        let newRegistration = (repos[idx].assist.enabled, repos[idx].assist.channel)
        saveRepos()
        if oldRegistration != newRegistration { assistConfigurationChangeHandler?() }
    }

    @discardableResult
    func saveRepoConfiguration(
        id: UUID,
        repoURL: String,
        branch: String,
        authorName: String,
        authorEmail: String,
        authMethod: GitAuthMethod,
        credentials: GitRemoteCredentials
    ) async -> Bool {
        guard let idx = repoIndex(id: id) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }

        let trimmedRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldRepo = repos[idx]

        if oldRepo.isCloned,
           !trimmedRepoURL.isEmpty,
           trimmedRepoURL != oldRepo.repoURL.trimmingCharacters(in: .whitespacesAndNewlines) {
            let vaultDir = vaultURL(for: id)
            let gitService = gitRepositoryFactory(vaultDir)
            if gitService.hasGitDirectory {
                let cloneURL = GitRemoteURL.cloneURLString(from: trimmedRepoURL) ?? trimmedRepoURL
                do {
                    try await gitService.setRemoteURL(name: "origin", url: cloneURL)
                } catch {
                    showError(message: String(localized: "Failed to update origin remote: \(error.localizedDescription)"))
                    return false
                }
            }
        }

        // The remote update suspends; the repository may have been removed or
        // the array reordered while it was in flight.
        guard let currentIndex = repoIndex(id: id) else {
            showError(message: String(localized: "Repository not found"))
            return false
        }
        repos[currentIndex].repoURL = trimmedRepoURL
        repos[currentIndex].branch = branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : branch.trimmingCharacters(in: .whitespacesAndNewlines)
        repos[currentIndex].authorName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        repos[currentIndex].authorEmail = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        repos[currentIndex].authMethod = authMethod
        repos[currentIndex].authUsername = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if authMethod == .gitHubPAT {
            // Preserve an existing account binding. Editing unrelated settings
            // (author, branch, URL) must not silently re-point an already-bound
            // repository at whichever GitHub account happens to be active —
            // that would swap the token identity used for pushes.
            let existingLogin = repos[currentIndex].gitHubAccountLogin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if oldRepo.authMethod != .gitHubPAT || existingLogin.isEmpty {
                repos[currentIndex].gitHubAccountLogin = activeGitHubAccountLogin
            }
        } else {
            repos[currentIndex].gitHubAccountLogin = nil
        }

        switch authMethod {
        case .httpsToken, .sshKey:
            saveRemoteCredentials(credentials, for: id)
        case .gitHubPAT, .none:
            clearRemoteCredentials(for: id)
        }

        repoMutationGeneration[id, default: 0] += 1
        saveRepos()
        detectChanges(repoID: id)
        return true
    }

    // MARK: - OAuth

    func signInWithGitHub() async {
        do {
            let token = try await OAuthService.shared.signIn()
            try await activateGitHubAccount(token: token)
        } catch let oauthError as OAuthError where oauthError.isCancelled {
            // User cancelled — do nothing
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func signInWithPAT(token: String) async {
        do {
            try await activateGitHubAccount(token: token)
        } catch {
            showError(message: String(localized: "Invalid token: \(error.localizedDescription)"))
        }
    }

    func switchGitHubAccount(login: String) async {
        guard let account = gitHubAccounts.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }),
              gitHubToken(for: account.login)?.isEmpty == false
        else { return }

        activeGitHubAccountLogin = account.login
        isSignedIn = true
        applyGitHubAccount(account)
        gitHubRepos = []
        saveGlobalSettings()
        await refreshRepos()
    }

    private func activateGitHubAccount(token: String) async throws {
        syncProgress = String(localized: "Fetching profile...")
        let user = try await GitHubService.fetchUser(token: token)
        let email: String
        if let userEmail = user.email, !userEmail.isEmpty {
            email = userEmail
        } else {
            email = try await GitHubService.fetchPrimaryEmail(token: token) ?? ""
        }

        let account = GitHubAccount(
            login: user.login,
            displayName: user.name ?? user.login,
            avatarURL: user.avatar_url ?? "",
            email: email
        )

        if let existingIndex = gitHubAccounts.firstIndex(where: { $0.login.caseInsensitiveCompare(account.login) == .orderedSame }) {
            gitHubAccounts[existingIndex] = account
        } else {
            gitHubAccounts.append(account)
        }

        activeGitHubAccountLogin = account.login
        KeychainService.save(key: Self.gitHubTokenKey(for: account.login), value: token)
        KeychainService.delete(key: "github_pat")
        isSignedIn = true
        applyGitHubAccount(account)

        isLoadingRepos = true
        defer { isLoadingRepos = false }
        gitHubRepos = try await GitHubService.fetchRepos(token: token)

        migrateRepoAccountOwnershipIfNeeded()
        saveGlobalSettings()
    }

    func refreshRepos() async {
        let token = pat
        guard !token.isEmpty else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            gitHubRepos = try await GitHubService.fetchRepos(token: token)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    func hydrateGitHubProfileIfNeeded() async {
        let token = pat
        guard !token.isEmpty else { return }

        let needsProfile = gitHubUsername.isEmpty
            || gitHubDisplayName.isEmpty
            || defaultAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || defaultAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard needsProfile else { return }

        do {
            let user = try await GitHubService.fetchUser(token: token)

            if gitHubUsername.isEmpty {
                gitHubUsername = user.login
            }
            if gitHubDisplayName.isEmpty {
                gitHubDisplayName = user.name ?? user.login
            }
            if gitHubAvatarURL.isEmpty {
                gitHubAvatarURL = user.avatar_url ?? ""
            }
            if defaultAuthorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaultAuthorName = user.name ?? user.login
            }
            if defaultAuthorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let email = user.email, !email.isEmpty {
                    defaultAuthorEmail = email
                } else if let email = try await GitHubService.fetchPrimaryEmail(token: token), !email.isEmpty {
                    defaultAuthorEmail = email
                }
            }

            saveGlobalSettings()
        } catch {
            // Best-effort hydration for older sessions; keep existing values if unavailable.
        }
    }

    func signOut() {
        if isDemoMode {
            deactivateDemoMode()
            return
        }

        let login = activeGitHubAccountLogin
        if login.isEmpty {
            KeychainService.delete(key: "github_pat")
            clearGitHubSession()
        } else {
            removeGitHubAccount(login: login)
        }
        saveGlobalSettings()
    }

    func removeGitHubAccount(login: String) {
        KeychainService.delete(key: Self.gitHubTokenKey(for: login))
        gitHubAccounts.removeAll { $0.login.caseInsensitiveCompare(login) == .orderedSame }

        activeGitHubAccountLogin = gitHubAccounts.first(where: { gitHubToken(for: $0.login)?.isEmpty == false })?.login ?? ""
        if let account = activeGitHubAccount {
            isSignedIn = true
            applyGitHubAccount(account)
            gitHubRepos = []
        } else {
            clearGitHubSession()
        }
    }

    private func clearGitHubSession() {
        isSignedIn = false
        activeGitHubAccountLogin = ""
        gitHubUsername = ""
        gitHubDisplayName = ""
        gitHubAvatarURL = ""
        defaultAuthorName = ""
        defaultAuthorEmail = ""
        gitHubRepos = []
        isLoadingRepos = false
        hasCompletedOnboarding = false
    }

    // MARK: - Pull Outcome State

    private func setPullOutcome(repoID: UUID, kind: PullOutcomeKind, message: String) {
        pullOutcomeByRepo[repoID] = PullOutcomeState(kind: kind, message: message, date: Date())
    }

    func clearCommitHistoryCache(for repoID: UUID) {
        commitHistoryByRepo.removeValue(forKey: repoID)
        commitHistoryHasMoreByRepo.removeValue(forKey: repoID)
        commitDetailByRepo.removeValue(forKey: repoID)
    }

    // MARK: - Error Handling

    func showError(message: String, category: String = "general") {
        lastError = message
        showError = true
        DebugLogger.shared.error(category, message)
    }

    // MARK: - Demo Mode

    func activateDemoMode() {
        isDemoMode = true
        isSignedIn = true
        gitHubUsername = "demo-user"
        gitHubDisplayName = "Demo User"
        gitHubAvatarURL = ""
        defaultAuthorName = "Demo User"
        defaultAuthorEmail = "demo@example.com"

        // Create a demo repo that appears already cloned with sample content
        let demoRepo = RepoConfig(
            repoURL: "https://github.com/demo-user/my-project.git",
            branch: "main",
            authorName: "Demo User",
            authorEmail: "demo@example.com",
            vaultFolderName: "my-project",
            gitState: GitState(
                commitSHA: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                treeSHA: "f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5",
                branch: "main",
                blobSHAs: [:],
                lastSyncDate: Date()
            )
        )

        repos = [demoRepo]
        saveRepos()
        saveGlobalSettings()

        // Write sample markdown files to the vault directory
        createDemoFiles(for: demoRepo)

        // Set a fake change count so the reviewer can see the push UI
        changeCounts[demoRepo.id] = 2
    }

    func deactivateDemoMode() {
        let demoRepos = repos
        isDemoMode = false
        clearGitHubSession()

        // Remove demo repo files
        for repo in demoRepos {
            let vaultDir = vaultURL(for: repo.id)
            try? FileManager.default.removeItem(at: vaultDir)
            clearCachedRepoState(for: repo.id)
        }
        repos = []
        saveRepos(replaceAll: true)
        isSyncing = false
        syncingRepoID = nil
        syncProgress = ""
        callbackNavigateToRepoID = nil
        callbackResult = nil
        pendingLFSAutoTrackingConfirmation = nil
        saveGlobalSettings()
    }

    private func createDemoFiles(for repo: RepoConfig) {
        let vaultDir = repo.defaultVaultURL
        let fm = FileManager.default

        // Create vault directory
        try? fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        // Create a fake .git directory so the app considers it cloned
        let gitDir = vaultDir.appendingPathComponent(".git", isDirectory: true)
        try? fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        // Write a minimal HEAD file
        let headFile = gitDir.appendingPathComponent("HEAD")
        try? "ref: refs/heads/main\n".write(to: headFile, atomically: true, encoding: .utf8)

        let sampleFiles: [(String, String)] = [
            ("README.md", """
            # Welcome to GitSync.md 👋

            This is a **demo repository** showing how GitSync.md works.

            ## Features
            - 📥 **Pull** — fetch the latest changes from GitHub
            - 📤 **Push** — commit and push your local edits
            - 🔄 **Sync** — keep any repo in sync between your iPhone and GitHub

            ## How It Works
            1. Sign in with GitHub
            2. Pick a repository (or enter any URL)
            3. Clone it to your iPhone
            4. Edit files in the **Files** app or any app that reads from it
            5. Push your changes back to GitHub

            > Files live in the **Files** app under `On My iPhone › GitSync.md`
            """),
            ("notes/meeting-2026-02-10.md", """
            # Team Standup — Feb 10, 2026

            - Shipped v1.0 to App Store 🚀
            - Next sprint: collaboration features
            - @alice to investigate conflict resolution

            ## Product Review (Feb 7)
            - Approved new sync indicator design
            - Decided on 3-way merge strategy
            - Launch marketing site by end of month

            ### Action Items
            - [ ] Update onboarding flow
            - [ ] Add pull-to-refresh animation
            - [x] Fix branch detection on clone
            """),
            ("notes/ideas.md", """
            # Ideas & Backlog

            ## 🟢 In Progress
            - iPad split-view support
            - Conflict resolution UI

            ## 🔵 Planned
            - Branch switching
            - Multiple repository support
            - Shared team repositories

            ## 💡 Someday
            - End-to-end encryption option
            - Widget for sync status
            - Shortcuts integration
            """),
            ("config/settings.json", """
            {
              "project": "my-project",
              "version": "1.0.0",
              "sync": {
                "branch": "main",
                "autoCommit": false
              }
            }
            """),
        ]

        for (path, content) in sampleFiles {
            let fileURL = vaultDir.appendingPathComponent(path)
            let dir = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Callback Result State

/// Displayed briefly in the UI after a callback operation completes,
/// before redirecting back to the calling app.
struct CallbackResultState: Equatable {
    let repoID: UUID
    let action: String
    let isSuccess: Bool
    let message: String
}
