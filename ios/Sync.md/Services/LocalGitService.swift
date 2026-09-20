import Foundation
import CryptoKit
import Clibgit2
import libgit2
import os

// MARK: - Errors

enum LocalGitError: LocalizedError {
    case suspiciousChanges(SyncSafetyReview)
    case notCloned
    case invalidRemoteURL
    case cloneFailed(String)
    case fetchFailed(String)
    case pushFailed(String)
    case commitFailed(String)
    case noChanges
    case stashNothingToSave
    case stashNotFound(Int)
    case stashApplyConflict
    case pullBlockedByLocalChanges
    case pullDiverged
    case pullRemoteBranchMissing(String)
    case wrongBranch(expected: String, actual: String)
    case checkoutBlockedByLocalChanges
    case branchAlreadyExists(String)
    case branchNotFound(String)
    case branchIsCurrent(String)
    case mergeBlockedByLocalChanges
    case mergeConflictsDetected
    case rebaseConflictsDetected
    case conflictSessionInProgress(ConflictSessionKind)
    case revertBlockedByLocalChanges
    case noMergeInProgress
    case noRebaseInProgress
    case conflictPathNotFound(String)
    case tagAlreadyExists(String)
    case tagNotFound(String)
    case repositoryCorrupted(String)
    case lfsFailed(String)
    /// Push is blocked because staged/committed large files are ordinary Git
    /// blobs instead of Git LFS pointers. Distinct from `lfsFailed` so the UI
    /// can offer the explicit LFS repair path for exactly this condition.
    case lfsLargeBlobsNotTracked(String)
    case lfsRepairBlocked(LFSRepairBlockReason)
    case invalidAuthorIdentity(String)
    case authenticationFailed(String)
    case sshHostKeyTrustRequired(GitLFSSSHHostKeyTrustError)
    case libgit2(String)

    var requiresUserAction: Bool {
        switch self {
        case .authenticationFailed, .sshHostKeyTrustRequired, .invalidAuthorIdentity,
             .repositoryCorrupted, .suspiciousChanges, .conflictSessionInProgress,
             .lfsLargeBlobsNotTracked, .lfsRepairBlocked, .invalidRemoteURL: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .suspiciousChanges(let review):
            return "\(review.paths.count) unexpected file changes need your review. Previous versions are protected; nothing has been uploaded."
        case .notCloned:
            return String(localized: "Repository not cloned yet. Clone it first.")
        case .invalidRemoteURL:
            return String(localized: "Invalid remote URL.")
        case .cloneFailed(let msg):
            return String(localized: "Clone failed: \(msg)")
        case .fetchFailed(let msg):
            return String(localized: "Fetch failed: \(msg)")
        case .pushFailed(let msg):
            return String(localized: "Push failed: \(msg)")
        case .commitFailed(let msg):
            return String(localized: "Commit failed: \(msg)")
        case .noChanges:
            return String(localized: "No changes to commit.")
        case .stashNothingToSave:
            return String(localized: "No local changes to stash.")
        case .stashNotFound(let index):
            return String(localized: "Stash at index \(index) was not found.")
        case .stashApplyConflict:
            return String(localized: "Applying stash would overwrite local changes. Commit, stash, or discard local edits first.")
        case .pullBlockedByLocalChanges:
            return String(localized: "Pull blocked to protect local edits. Commit, stash, or discard local changes first.")
        case .pullDiverged:
            return String(localized: "Pull requires a merge because local and remote have diverged.")
        case .pullRemoteBranchMissing(let branch):
            return String(localized: "Remote branch '\(branch)' was not found on origin.")
        case .wrongBranch(let expected, let actual):
            return String(localized: "GitSync Assist expected branch '\(expected)', but '\(actual)' is checked out.")
        case .checkoutBlockedByLocalChanges:
            return String(localized: "Switching branches is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .branchAlreadyExists(let name):
            return String(localized: "Branch '\(name)' already exists.")
        case .branchNotFound(let name):
            return String(localized: "Branch '\(name)' was not found.")
        case .branchIsCurrent(let name):
            return String(localized: "Cannot delete the currently checked out branch '\(name)'.")
        case .mergeBlockedByLocalChanges:
            return String(localized: "Merge is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .mergeConflictsDetected:
            return String(localized: "Merge produced conflicts that require manual resolution.")
        case .rebaseConflictsDetected:
            return String(localized: "Rebase produced conflicts that require manual resolution.")
        case .conflictSessionInProgress(let kind):
            switch kind {
            case .rebase:
                return String(localized: "A rebase is still in progress. Resolve its conflicts and continue, or abort the rebase, before committing new changes.")
            case .merge:
                return String(localized: "A merge is still in progress. Resolve its conflicts and complete the merge, or abort it, before committing new changes.")
            default:
                return String(localized: "Conflict resolution is still in progress. Finish or abort it before committing new changes.")
            }
        case .revertBlockedByLocalChanges:
            return String(localized: "Revert is blocked to protect local edits. Commit, stash, or discard changes first.")
        case .noMergeInProgress:
            return String(localized: "No merge is currently in progress.")
        case .noRebaseInProgress:
            return String(localized: "No rebase is currently in progress.")
        case .conflictPathNotFound(let path):
            return String(localized: "No active conflict found for '\(path)'.")
        case .tagAlreadyExists(let name):
            return String(localized: "Tag '\(name)' already exists.")
        case .tagNotFound(let name):
            return String(localized: "Tag '\(name)' was not found.")
        case .repositoryCorrupted(let msg):
            return String(localized: "Repository corrupted: \(msg). Try removing and re-cloning.")
        case .lfsFailed(let msg):
            return String(localized: "Git LFS failed: \(msg)")
        case .lfsLargeBlobsNotTracked(let msg):
            return String(localized: "Git LFS failed: \(msg)")
        case .lfsRepairBlocked(let reason):
            return reason.message
        case .invalidAuthorIdentity(let msg):
            return String(localized: "Git author identity is missing or invalid. \(msg) Open repository settings and set Author Name and Author Email.")
        case .authenticationFailed(let msg):
            return String(localized: "Authentication failed: \(msg)")
        case .sshHostKeyTrustRequired(let error):
            return error.localizedDescription
        case .libgit2(let msg):
            return String(localized: "Git error: \(msg)")
        }
    }
}

/// Why the explicit Git LFS history repair refused to run. Every reason leaves
/// the repository completely untouched.
enum LFSRepairBlockReason: Equatable, Sendable {
    case conflictSessionActive
    case dirtyWorkingTree
    case detachedHead
    case remoteBranchMissing(String)
    case diverged(behindBy: Int)
    case mergeCommitInUnpushedRange(String)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case branchChangedDuringRepair

    var message: String {
        switch self {
        case .conflictSessionActive:
            return String(localized: "LFS repair is blocked: a merge or rebase is in progress. Finish or abort it first.")
        case .dirtyWorkingTree:
            return String(localized: "LFS repair is blocked: there are uncommitted local changes. Sync or commit them first.")
        case .detachedHead:
            return String(localized: "LFS repair is blocked: the repository is not on a branch.")
        case .remoteBranchMissing(let branch):
            return String(localized: "LFS repair is blocked: branch '\(branch)' has no matching branch on origin, so the unpushed range is ambiguous.")
        case .diverged(let behindBy):
            return String(localized: "LFS repair is blocked: the remote has \(behindBy) commit(s) this device does not. Sync first, then repair.")
        case .mergeCommitInUnpushedRange(let sha):
            return String(localized: "LFS repair is blocked: unpushed commit \(String(sha.prefix(7))) is a merge commit, which this repair does not rewrite.")
        case .insufficientDiskSpace(let required, let available):
            let fmt = ByteCountFormatter()
            return String(localized: "LFS repair needs \(fmt.string(fromByteCount: required)) of free space to copy large files into Git LFS storage, but only \(fmt.string(fromByteCount: available)) is available.")
        case .branchChangedDuringRepair:
            return String(localized: "LFS repair stopped because the branch changed while it was working. The original branch and repair backup remain intact; run the repair again after other Git activity finishes.")
        }
    }
}

/// Result of the explicit repair that converts strictly-unpushed large blobs
/// into Git LFS pointers.
struct GitLFSRepairResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// No unpushed commit contains an offending large blob; nothing changed.
        case nothingToRepair
        /// Unpushed commits were rewritten in place with pointer blobs.
        case repaired
    }

    let outcome: Outcome
    let rewrittenCommitCount: Int
    let convertedPaths: [String]
    let convertedByteCount: Int64
    let backupRefName: String?
    let newHeadSHA: String
}

// MARK: - Result Types

struct LocalCloneResult: Sendable {
    let commitSHA: String
    let branch: String
    let fileCount: Int
    let lfsWarning: String?

    init(commitSHA: String, branch: String, fileCount: Int, lfsWarning: String? = nil) {
        self.commitSHA = commitSHA
        self.branch = branch
        self.fileCount = fileCount
        self.lfsWarning = lfsWarning
    }
}

struct LocalPullResult: Sendable {
    let updated: Bool
    let newCommitSHA: String
}

struct LocalPushResult: Sendable {
    let commitSHA: String
}

struct LocalRepoInfo: Sendable {
    let branch: String
    let commitSHA: String
    let changeCount: Int
    let syncState: RepoSyncState
    let statusEntries: [GitStatusEntry]
    let remoteCommitSHA: String

    init(
        branch: String,
        commitSHA: String,
        changeCount: Int,
        syncState: RepoSyncState = .unknown,
        statusEntries: [GitStatusEntry] = [],
        remoteCommitSHA: String = ""
    ) {
        self.branch = branch
        self.commitSHA = commitSHA
        self.changeCount = changeCount
        self.syncState = syncState
        self.statusEntries = statusEntries
        self.remoteCommitSHA = remoteCommitSHA
    }
}

// MARK: - libgit2 Helpers

/// Get the last libgit2 error message.
private func git2ErrorMessage(fallback: String? = nil) -> String {
    if let err = git_error_last(), let message = err.pointee.message {
        let trimmed = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.lowercased() != "no error" {
            return trimmed
        }
    }

    if let fallback {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }

    return String(localized: "Unknown git error")
}

/// Call a libgit2 function and throw if it returns an error code.
@discardableResult
private func git2Check(_ code: Int32, context: String = "", fallback: String? = nil) throws -> Int32 {
    guard code >= 0 else {
        let msg = git2ErrorMessage(fallback: fallback)
        let full = context.isEmpty ? msg : "\(context): \(msg)"
        throw LocalGitError.libgit2(full)
    }
    return code
}

/// Like `git2Check`, but preserves SSH host-key trust failures captured by the
/// transport callback instead of flattening them into a generic libgit2 error.
@discardableResult
private func git2TransportCheck(
    _ code: Int32,
    context: String = "",
    fallback: String? = nil,
    credentialContext: CredentialContext,
    wrapping: (String) -> LocalGitError
) throws -> Int32 {
    guard code >= 0 else {
        if let sshHostKeyTrustError = credentialContext.sshHostKeyTrustError {
            throw LocalGitError.sshHostKeyTrustRequired(sshHostKeyTrustError)
        }
        let msg = credentialContext.callbackErrorMessage ?? git2ErrorMessage(fallback: fallback)
        let full = context.isEmpty ? msg : "\(context): \(msg)"
        if credentialContext.callbackErrorMessage != nil {
            throw LocalGitError.authenticationFailed(full)
        }
        throw wrapping(full)
    }
    return code
}

private struct GitSignatureIdentity {
    let name: String
    let email: String
}

private func validatedGitSignatureIdentity(authorName: String, authorEmail: String) throws -> GitSignatureIdentity {
    let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    let email = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !name.isEmpty else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Name is required."))
    }
    guard !email.isEmpty else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Email is required."))
    }
    let forbiddenNameCharacters = CharacterSet(charactersIn: "<>\n\r")
    guard name.rangeOfCharacter(from: forbiddenNameCharacters) == nil else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Name cannot contain line breaks or angle brackets."))
    }

    let forbiddenEmailCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>"))
    guard email.contains("@"), email.rangeOfCharacter(from: forbiddenEmailCharacters) == nil else {
        throw LocalGitError.invalidAuthorIdentity(String(localized: "Author Email must look like you@example.com."))
    }

    return GitSignatureIdentity(name: name, email: email)
}

private func createGitSignature(
    _ signature: inout UnsafeMutablePointer<git_signature>?,
    authorName: String,
    authorEmail: String
) throws {
    let identity = try validatedGitSignatureIdentity(authorName: authorName, authorEmail: authorEmail)
    guard git_signature_now(&signature, identity.name, identity.email) >= 0 else {
        throw LocalGitError.invalidAuthorIdentity(
            git2ErrorMessage(fallback: "Author Name or Author Email was rejected by Git.")
        )
    }
}

/// Convert a `git_oid` pointer to a 40-char hex string.
private func oidToHex(_ oid: UnsafePointer<git_oid>) -> String {
    // SHA-1 hex is 40 chars + null terminator
    let bufSize = 41
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
    defer { buf.deallocate() }
    git_oid_tostr(buf, bufSize, oid)
    return String(cString: buf)
}

/// Build a `git_strarray` from a single string. The caller must keep `cStr` alive.
private func makeStrarray(_ cStr: UnsafeMutablePointer<CChar>, into arr: inout git_strarray, storage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    storage.pointee = cStr
    arr.strings = storage
    arr.count = 1
}

// MARK: - Credential Callback

/// Context passed through libgit2's credential callback payload.
private class CredentialContext {
    let credentials: GitRemoteCredentials
    let remoteURL: String?
    let hostKeyTrustStore: any GitLFSSSHHostKeyTrustStore
    var didAttemptUsername = false
    var didAttemptUserPass = false
    var didAttemptSSHKey = false
    var didAttemptDefault = false
    private(set) var callbackErrorMessage: String?
    private(set) var sshHostKeyTrustError: GitLFSSSHHostKeyTrustError?

    init(
        credentials: GitRemoteCredentials,
        remoteURL: String? = nil,
        hostKeyTrustStore: any GitLFSSSHHostKeyTrustStore = GitLFSSSHHostKeyFileTrustStore.default
    ) {
        self.credentials = credentials
        self.remoteURL = remoteURL
        self.hostKeyTrustStore = hostKeyTrustStore
    }

    func resetAttempts() {
        didAttemptUsername = false
        didAttemptUserPass = false
        didAttemptSSHKey = false
        didAttemptDefault = false
        callbackErrorMessage = nil
        sshHostKeyTrustError = nil
    }

    func recordCallbackError(_ message: String) {
        callbackErrorMessage = message
    }

    func recordSSHHostKeyTrustError(_ error: GitLFSSSHHostKeyTrustError) {
        sshHostKeyTrustError = error
        callbackErrorMessage = error.localizedDescription
    }

    func failCredential(_ message: String) -> Int32 {
        recordCallbackError(message)
        return GIT_EUSER.rawValue
    }
}

private func credentialMethodDescription(_ method: GitAuthMethod) -> String {
    switch method {
    case .gitHubPAT:
        return String(localized: "GitHub token")
    case .none:
        return String(localized: "no credentials")
    case .httpsToken:
        return String(localized: "HTTPS username/token")
    case .sshKey:
        return String(localized: "SSH key")
    }
}

private func credentialTypesDescription(_ allowedTypes: UInt32) -> String {
    var names: [String] = []
    if allowedTypes & GIT_CREDENTIAL_USERNAME.rawValue != 0 { names.append(String(localized: "username")) }
    if allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 { names.append(String(localized: "username/password")) }
    if allowedTypes & GIT_CREDENTIAL_SSH_KEY.rawValue != 0 || allowedTypes & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0 { names.append(String(localized: "SSH key")) }
    if allowedTypes & GIT_CREDENTIAL_DEFAULT.rawValue != 0 { names.append(String(localized: "default system credentials")) }
    return names.isEmpty ? String(localized: "credentials") : names.joined(separator: ", ")
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string, !string.isEmpty else { return body(nil) }
    return string.withCString { body($0) }
}

private func preferredUsername(from ctx: CredentialContext, usernameFromURL: UnsafePointer<CChar>?) -> String {
    let configured = ctx.credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty { return configured }
    if let usernameFromURL { return String(cString: usernameFromURL) }
    if ctx.credentials.method == .sshKey { return "git" }
    if ctx.credentials.method == .gitHubPAT { return "x-access-token" }
    return ""
}

private func acquireCredential(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    context ctx: CredentialContext
) -> Int32 {
    let credentials = ctx.credentials
    let username = preferredUsername(from: ctx, usernameFromURL: usernameFromURL)
    let requestedCredentials = credentialTypesDescription(allowedTypes)

    if allowedTypes & GIT_CREDENTIAL_USERNAME.rawValue != 0, usernameFromURL == nil, !username.isEmpty {
        if ctx.didAttemptUsername {
            return ctx.failCredential(String(localized: "The remote rejected the username '\(username)'. Check the repository credentials."))
        }
        ctx.didAttemptUsername = true
        let code = git_credential_username_new(cred, username)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not create username credentials for '\(username)'.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0 || allowedTypes & GIT_CREDENTIAL_SSH_KEY.rawValue != 0 {
        guard credentials.method == .sshKey else {
            return ctx.failCredential(String(localized: "The remote requested SSH credentials, but this repository is configured for \(credentialMethodDescription(credentials.method))."))
        }
        guard !credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ctx.failCredential(String(localized: "The remote requested an SSH key, but no private key is saved for this repository."))
        }
        guard !username.isEmpty else {
            return ctx.failCredential(String(localized: "The remote requested an SSH key, but no SSH username is configured."))
        }
        if ctx.didAttemptSSHKey {
            return ctx.failCredential(String(localized: "The remote rejected the saved SSH key. Check that the key has access to this repository and that the passphrase is correct."))
        }
        ctx.didAttemptSSHKey = true

        // `libssh2_userauth_publickey_frommemory` accepts a nil public key and
        // derives it from the private key. Prefer that path because Forgejo and
        // OpenSSH commonly expose public keys in authorized_keys format
        // (`ecdsa-sha2-nistp256 AAAA... comment`), while libssh2's memory API
        // can treat that text as malformed key material and the server rejects
        // authentication before it ever checks the private-key signature.
        let passphrase = credentials.passphrase.isEmpty ? nil : credentials.passphrase

        let code = username.withCString { usernameC in
            credentials.privateKey.withCString { privateKeyC in
                withOptionalCString(passphrase) { passphraseC in
                    git_credential_ssh_key_memory_new(
                        cred,
                        usernameC,
                        nil,
                        privateKeyC,
                        passphraseC
                    )
                }
            }
        }
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not load the saved SSH key. Check the key format and passphrase.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 {
        guard credentials.method == .gitHubPAT || credentials.method == .httpsToken else {
            return ctx.failCredential(String(localized: "The remote requested HTTPS username/password credentials, but this repository is configured for \(credentialMethodDescription(credentials.method))."))
        }
        guard !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if credentials.method == .gitHubPAT {
                return ctx.failCredential(String(localized: "GitHub authentication is selected, but no GitHub token is saved. Sign in again or reconnect GitHub."))
            }
            return ctx.failCredential(String(localized: "The remote requested HTTPS credentials, but no token or password is saved for this repository."))
        }
        if ctx.didAttemptUserPass {
            return ctx.failCredential(String(localized: "The remote rejected the saved token/password. Check that it has access to this repository."))
        }
        ctx.didAttemptUserPass = true

        let effectiveUsername = username.isEmpty ? "x-access-token" : username
        let code = git_credential_userpass_plaintext_new(cred, effectiveUsername, credentials.password)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not create HTTPS credentials.")))
        }
        return code
    }

    if allowedTypes & GIT_CREDENTIAL_DEFAULT.rawValue != 0 {
        if ctx.didAttemptDefault {
            return ctx.failCredential(String(localized: "The remote rejected the default system credentials."))
        }
        ctx.didAttemptDefault = true
        let code = git_credential_default_new(cred)
        if code < 0 {
            ctx.recordCallbackError(git2ErrorMessage(fallback: String(localized: "Could not load default system credentials.")))
        }
        return code
    }

    if credentials.method == .none {
        return ctx.failCredential(String(localized: "The remote requested authentication (\(requestedCredentials)), but no credentials are configured for this repository."))
    }
    return ctx.failCredential(String(localized: "The remote requested \(requestedCredentials), but the saved \(credentialMethodDescription(credentials.method)) credentials are not compatible."))
}

/// libgit2 credential callback for HTTPS/PAT and SSH-key authentication.
nonisolated private func credentialCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return GIT_EUSER.rawValue }
    let ctx = Unmanaged<CredentialContext>.fromOpaque(payload).takeUnretainedValue()
    return acquireCredential(
        cred: cred,
        usernameFromURL: usernameFromURL,
        allowedTypes: allowedTypes,
        context: ctx
    )
}

nonisolated private func sshSHA256Fingerprint(from cert: UnsafeMutablePointer<git_cert>) -> String? {
    let hostKey = UnsafeMutableRawPointer(cert).assumingMemoryBound(to: git_cert_hostkey.self).pointee
    guard hostKey.type.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 else { return nil }

    let digest = withUnsafeBytes(of: hostKey.hash_sha256) { bytes in
        Data(bytes.prefix(32))
    }
    let base64 = digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    return "SHA256:\(base64)"
}

nonisolated private func sshHostAndPort(for callbackHost: String, remoteURL: String?) -> (host: String, port: Int) {
    if let remoteURL,
       let remote = GitRemoteURL.parse(remoteURL),
       remote.isSSH,
       let host = remote.host,
       !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (GitLFSSSHHostKeyFileTrustStore.normalizeHost(host), remote.sshPort ?? 22)
    }
    return (GitLFSSSHHostKeyFileTrustStore.normalizeHost(callbackHost), 22)
}

/// Host-key/certificate callback. HTTPS keeps libgit2's platform certificate
/// validation. SSH remotes are pinned through GitSync.md's known-hosts store:
/// first use is blocked until the user explicitly trusts the displayed
/// SHA-256 host-key fingerprint, and later key changes are rejected.
nonisolated private func certificateCheckCallback(
    cert: UnsafeMutablePointer<git_cert>?,
    valid: Int32,
    host: UnsafePointer<CChar>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    let hostName = host.map { String(cString: $0) } ?? String(localized: "the remote host")
    guard let payload, let cert else { return GIT_ECERTIFICATE.rawValue }

    let ctx = Unmanaged<CredentialContext>.fromOpaque(payload).takeUnretainedValue()
    if cert.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2 {
        guard ctx.credentials.method == .sshKey else {
            ctx.recordCallbackError(String(localized: "SSH host key verification failed for \(hostName). Configure this repository with SSH key credentials or use HTTPS."))
            return GIT_ECERTIFICATE.rawValue
        }
        guard let fingerprint = sshSHA256Fingerprint(from: cert) else {
            ctx.recordCallbackError(String(localized: "SSH host key verification failed for \(hostName). The server did not provide a SHA-256 host-key fingerprint."))
            return GIT_ECERTIFICATE.rawValue
        }

        let (trustedHost, trustedPort) = sshHostAndPort(for: hostName, remoteURL: ctx.remoteURL)
        do {
            try ctx.hostKeyTrustStore.validate(fingerprint: fingerprint, host: trustedHost, port: trustedPort)
            return 0
        } catch let error as GitLFSSSHHostKeyTrustError {
            ctx.recordSSHHostKeyTrustError(error)
            return GIT_ECERTIFICATE.rawValue
        } catch {
            ctx.recordCallbackError(error.localizedDescription)
            return GIT_ECERTIFICATE.rawValue
        }
    }

    if valid != 0 { return 0 }
    ctx.recordCallbackError(String(localized: "TLS certificate verification failed for \(hostName). Check your network or the remote's certificate."))
    return GIT_ECERTIFICATE.rawValue
}

// MARK: - Push Callbacks

/// Context for push operations — combines credentials with per-ref rejection tracking.
///
/// `git_remote_push` returns 0 on network success even when the remote rejects
/// individual refs (non-fast-forward, protected branch, pre-receive hook). The
/// only way to detect those rejections is via the `push_update_reference`
/// callback, which is called once per ref with a non-nil `status` string when
/// that ref was rejected.
private final class PushContext: CredentialContext {
    var rejectedRefs: [(refname: String, reason: String)] = []
}

nonisolated private func pushCredentialCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return GIT_EUSER.rawValue }
    let ctx = Unmanaged<PushContext>.fromOpaque(payload).takeUnretainedValue()
    return acquireCredential(
        cred: cred,
        usernameFromURL: usernameFromURL,
        allowedTypes: allowedTypes,
        context: ctx
    )
}

nonisolated private func pushUpdateReferenceCallback(
    refname: UnsafePointer<CChar>?,
    status: UnsafePointer<CChar>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload else { return 0 }
    let ctx = Unmanaged<PushContext>.fromOpaque(payload).takeUnretainedValue()

    // A non-nil status means the remote rejected this ref update.
    if let status {
        let refnameString = refname.map { String(cString: $0) } ?? "(unknown)"
        let reason = String(cString: status)
        ctx.rejectedRefs.append((refname: refnameString, reason: reason))
    }
    return 0
}

private final class DiffPrintCollector {
    var output: String = ""
}

nonisolated private func diffPrintCallback(
    delta: UnsafePointer<git_diff_delta>?,
    hunk: UnsafePointer<git_diff_hunk>?,
    line: UnsafePointer<git_diff_line>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload, let line else { return 0 }
    let collector = Unmanaged<DiffPrintCollector>.fromOpaque(payload).takeUnretainedValue()

    // libgit2 strips the +/-/space origin from content; prepend it so the
    // emitted text is a well-formed unified diff that parsers can classify.
    let origin = UInt8(bitPattern: line.pointee.origin)
    switch origin {
    case UInt8(ascii: "F"), UInt8(ascii: "H"), UInt8(ascii: "B"):
        break
    default:
        collector.output.append(Character(Unicode.Scalar(origin)))
    }

    let length = Int(line.pointee.content_len)
    if let content = line.pointee.content, length > 0 {
        let data = Data(bytes: content, count: length)
        collector.output += String(decoding: data, as: UTF8.self)
    }

    return 0
}

private final class StashListCollector {
    var entries: [GitStashEntry] = []
}

nonisolated private func stashForeachCallback(
    index: Int,
    message: UnsafePointer<CChar>?,
    stashID: UnsafePointer<git_oid>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let payload, let stashID else { return 0 }
    let collector = Unmanaged<StashListCollector>.fromOpaque(payload).takeUnretainedValue()

    let oidHex = oidToHex(stashID)
    let entryMessage = message.map { String(cString: $0) } ?? ""
    collector.entries.append(GitStashEntry(index: Int(index), oid: oidHex, message: entryMessage))
    return 0
}

// MARK: - Local Git Service

/// Performs git operations using the libgit2 C library directly.
///
/// This produces a real `.git` directory on the iOS filesystem,
/// compatible with other git clients — including the Obsidian Git plugin.
/// Replaces the GitHub REST API approach which only stored file contents.
final class LocalGitService: GitRepositoryProtocol, @unchecked Sendable {
    let localURL: URL
    private let pullOnlyBeforeCheckout: (@Sendable () -> Void)?
    private let gitLFSServiceFactory: @Sendable (URL, GitRemoteCredentials) -> GitLFSService

    /// One-time libgit2 global init.
    private static let initOnce: Void = { git_libgit2_init() }()

    /// Set `core.precomposeunicode = true` on a repo so libgit2 transparently
    /// normalises filenames between NFC (git objects) and NFD (APFS/HFS+).
    /// Without this, Korean/Japanese/Chinese filenames appear as permanently
    /// modified and staging operations can silently mis-identify files.
    private static func setPrecomposeUnicode(repo: OpaquePointer?) {
        var config: OpaquePointer?
        defer { if let config { git_config_free(config) } }
        if git_repository_config(&config, repo) == 0, let config {
            git_config_set_bool(config, "core.precomposeunicode", 1)
        }
    }

    init(
        localURL: URL,
        pullOnlyBeforeCheckout: (@Sendable () -> Void)? = nil,
        gitLFSServiceFactory: @escaping @Sendable (URL, GitRemoteCredentials) -> GitLFSService = {
            GitLFSService(localURL: $0, credentials: $1)
        }
    ) {
        _ = Self.initOnce
        self.localURL = localURL
        self.pullOnlyBeforeCheckout = pullOnlyBeforeCheckout
        self.gitLFSServiceFactory = gitLFSServiceFactory
    }

    /// Whether a `.git` directory exists at the local URL.
    var hasGitDirectory: Bool {
        FileManager.default.fileExists(
            atPath: localURL.appendingPathComponent(".git").path
        )
    }

    // MARK: - Clone / Remote Configuration

    func setRemoteURL(name: String = "origin", url: String) async throws {
        let repoPath = self.localURL.path
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)

        try await Task.detached {
            guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
                throw LocalGitError.invalidRemoteURL
            }

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var existingRemote: OpaquePointer?
            let lookupCode = git_remote_lookup(&existingRemote, repo, trimmedName)
            if let existingRemote { git_remote_free(existingRemote) }

            if lookupCode == GIT_ENOTFOUND.rawValue {
                var createdRemote: OpaquePointer?
                defer { if let createdRemote { git_remote_free(createdRemote) } }
                try git2Check(
                    git_remote_create(&createdRemote, repo, trimmedName, trimmedURL),
                    context: "Create remote \(trimmedName)"
                )
            } else {
                try git2Check(lookupCode, context: "Lookup remote \(trimmedName)")
                try git2Check(
                    git_remote_set_url(repo, trimmedName, trimmedURL),
                    context: "Set remote \(trimmedName) URL"
                )
            }
        }.value
    }

    func clone(remoteURL: String, pat: String) async throws -> LocalCloneResult {
        let dest = self.localURL.path
        let localURL = self.localURL

        let result = try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }

            // Configure clone options with HTTPS/PAT and SSH-key callbacks.
            var opts = git_clone_options()
            git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))

            let ctx = CredentialContext(credentials: GitRemoteCredentials.fromTransportPayload(pat), remoteURL: remoteURL)
            let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
            defer { Unmanaged<CredentialContext>.fromOpaque(ctxPtr).release() }

            opts.fetch_opts.callbacks.credentials = credentialCallback
            opts.fetch_opts.callbacks.certificate_check = certificateCheckCallback
            opts.fetch_opts.callbacks.payload = ctxPtr

            let code = git_clone(&repo, remoteURL, dest, &opts)
            guard code == 0, let repo else {
                if let sshHostKeyTrustError = ctx.sshHostKeyTrustError {
                    throw LocalGitError.sshHostKeyTrustRequired(sshHostKeyTrustError)
                }
                throw LocalGitError.cloneFailed(
                    ctx.callbackErrorMessage ?? git2ErrorMessage(fallback: "git clone failed with error code \(code).")
                )
            }

            // Persist core.precomposeunicode so subsequent libgit2 calls on
            // this repo transparently handle NFC↔NFD for non-ASCII filenames.
            Self.setPrecomposeUnicode(repo: repo)

            // Read HEAD to get branch and commit SHA
            var head: OpaquePointer?
            defer { if let head { git_reference_free(head) } }
            try git2Check(git_repository_head(&head, repo), context: "Read HEAD after clone")

            let branch: String
            if let name = git_reference_shorthand(head) {
                branch = String(cString: name)
            } else {
                branch = "main"
            }

            let commitSHA = oidToHex(git_reference_target(head)!)
            let fileCount = Self.countFiles(in: localURL)

            return LocalCloneResult(commitSHA: commitSHA, branch: branch, fileCount: fileCount)
        }.value

        var lfsWarning: String?
        do {
            let lfsResult = try await Self.hydrateLFSIfNeeded(localURL: localURL, pat: pat)
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Hydrated Git LFS files after clone", detail: "\(lfsResult.checkedOutCount) files")
            }
        } catch LocalGitError.lfsFailed(let message) {
            lfsWarning = "Clone completed, but some Git LFS files could not be downloaded: \(message)"
            DebugLogger.shared.error("lfs", "Git LFS hydration after clone failed", detail: message)
        }

        return LocalCloneResult(
            commitSHA: result.commitSHA,
            branch: result.branch,
            fileCount: Self.countFiles(in: localURL),
            lfsWarning: lfsWarning
        )
    }

    // MARK: - Pull (Fetch + Planning + Safe Fast-Forward)

    func pullPlan(pat: String) async throws -> PullPlan {
        let path = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")

            // Mirror repoInfo(): persist core.precomposeunicode before any
            // status read so the dirty check agrees with the UI. Without
            // this, freshly-opened handles on repos cloned by older builds
            // can see NFC/NFD differences as uncommitted changes while the
            // health card (which sets the flag first) reports clean — and
            // the pull is blocked even though the workdir is logically clean.
            Self.setPrecomposeUnicode(repo: repo)

            var head: OpaquePointer?
            defer { if let head { git_reference_free(head) } }
            try git2Check(git_repository_head(&head, repo), context: "Read HEAD")

            let localOidPtr = git_reference_target(head)!
            let localCommitSHA = oidToHex(localOidPtr)
            let branch: String
            if let name = git_reference_shorthand(head) {
                branch = String(cString: name)
            } else {
                branch = "main"
            }

            try Self.fetchOrigin(repo: repo, pat: pat)

            let remoteRefName = "refs/remotes/origin/\(branch)"
            var remoteRef: OpaquePointer?
            defer { if let remoteRef { git_reference_free(remoteRef) } }
            let remoteLookupCode = git_reference_lookup(&remoteRef, repo, remoteRefName)
            if remoteLookupCode == GIT_ENOTFOUND.rawValue {
                return PullPlan(
                    action: .remoteBranchMissing,
                    branch: branch,
                    localCommitSHA: localCommitSHA,
                    remoteCommitSHA: "",
                    hasLocalChanges: try Self.hasUncommittedChanges(repo: repo),
                    aheadBy: 0,
                    behindBy: 0
                )
            }
            try git2Check(remoteLookupCode, context: "Lookup \(remoteRefName)")

            let remoteOidPtr = git_reference_target(remoteRef)!
            let remoteCommitSHA = oidToHex(remoteOidPtr)
            let hasLocalChanges = try Self.hasUncommittedChanges(repo: repo)

            if git_oid_equal(localOidPtr, remoteOidPtr) != 0 {
                return PullPlan(
                    action: .upToDate,
                    branch: branch,
                    localCommitSHA: localCommitSHA,
                    remoteCommitSHA: remoteCommitSHA,
                    hasLocalChanges: hasLocalChanges,
                    aheadBy: 0,
                    behindBy: 0
                )
            }

            var ahead: Int = 0
            var behind: Int = 0
            try git2Check(
                git_graph_ahead_behind(&ahead, &behind, repo, localOidPtr, remoteOidPtr),
                context: "Compute ahead/behind"
            )

            let action = Self.classifyPullAction(
                ahead: ahead,
                behind: behind,
                hasLocalChanges: hasLocalChanges
            )

            return PullPlan(
                action: action,
                branch: branch,
                localCommitSHA: localCommitSHA,
                remoteCommitSHA: remoteCommitSHA,
                hasLocalChanges: hasLocalChanges,
                aheadBy: ahead,
                behindBy: behind
            )
        }.value
    }

    func pull(pat: String) async throws -> LocalPullResult {
        let plan = try await pullPlan(pat: pat)

        switch plan.action {
        case .upToDate:
            let lfsResult = try await Self.hydrateLFSIfNeeded(localURL: localURL, pat: pat)
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Restored Git LFS files while already up to date", detail: "\(lfsResult.checkedOutCount) files")
            }
            return LocalPullResult(updated: false, newCommitSHA: plan.localCommitSHA)
        case .blockedByLocalChanges:
            throw LocalGitError.pullBlockedByLocalChanges
        case .diverged:
            throw LocalGitError.pullDiverged
        case .remoteBranchMissing:
            throw LocalGitError.pullRemoteBranchMissing(plan.branch)
        case .fastForward:
            return try await performSafeFastForward(branch: plan.branch, pat: pat, refetch: false, isPullOnly: false)
        }
    }

    func executePullOnly(pat: String, expectedBranch: String? = nil) async throws -> PullExecutionResult {
        try Task.checkCancellation()
        let plan = try await pullPlan(pat: pat)
        try Task.checkCancellation()
        if let expectedBranch, plan.branch != expectedBranch {
            throw LocalGitError.wrongBranch(expected: expectedBranch, actual: plan.branch)
        }
        switch plan.action {
        case .fastForward:
            do {
                try Task.checkCancellation()
                return PullExecutionResult(
                    plan: plan,
                    pullResult: try await performSafeFastForward(branch: plan.branch, pat: pat, refetch: false, isPullOnly: true)
                )
            } catch LocalGitError.pullBlockedByLocalChanges {
                // The working tree can change after fetch/planning but before
                // checkout. Preserve the typed, attention-worthy outcome.
                return PullExecutionResult(
                    plan: PullPlan(
                        action: .blockedByLocalChanges,
                        branch: plan.branch,
                        localCommitSHA: plan.localCommitSHA,
                        remoteCommitSHA: plan.remoteCommitSHA,
                        hasLocalChanges: true,
                        aheadBy: plan.aheadBy,
                        behindBy: plan.behindBy
                    ),
                    pullResult: nil
                )
            }
        case .upToDate:
            let lfsResult = try await Self.hydrateLFSIfNeeded(localURL: localURL, pat: pat)
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Restored Git LFS files while already up to date", detail: "\(lfsResult.checkedOutCount) files")
            }
            return PullExecutionResult(plan: plan, pullResult: nil)
        case .blockedByLocalChanges, .diverged, .remoteBranchMissing:
            return PullExecutionResult(plan: plan, pullResult: nil)
        }
    }

    func pullFastForward(branch: String, pat: String) async throws -> LocalPullResult {
        try await performSafeFastForward(branch: branch, pat: pat, refetch: false, isPullOnly: false)
    }

    func pullRebase(branch: String, pat: String, authorName: String, authorEmail: String) async throws -> LocalPullResult {
        try await performRebaseOntoOrigin(
            branch: branch,
            pat: pat,
            authorName: authorName,
            authorEmail: authorEmail,
            refetch: false
        )
    }

    private func performSafeFastForward(branch: String, pat: String, refetch: Bool, isPullOnly: Bool) async throws -> LocalPullResult {
        let path = self.localURL.path
        let localURL = self.localURL
        let pullOnlyBeforeCheckout = self.pullOnlyBeforeCheckout

        let fastForward = try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")

            Self.setPrecomposeUnicode(repo: repo)

            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.pullBlockedByLocalChanges
            }

            if refetch {
                try Self.fetchOrigin(repo: repo, pat: pat)
            }

            let remoteRefName = "refs/remotes/origin/\(branch)"
            var remoteRef: OpaquePointer?
            defer { if let remoteRef { git_reference_free(remoteRef) } }
            let remoteLookupCode = git_reference_lookup(&remoteRef, repo, remoteRefName)
            if remoteLookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.pullRemoteBranchMissing(branch)
            }
            try git2Check(remoteLookupCode, context: "Lookup \(remoteRefName)")

            var head: OpaquePointer?
            defer { if let head { git_reference_free(head) } }
            try git2Check(git_repository_head(&head, repo), context: "Read HEAD")

            // HEAD can be changed by another process after fetch/planning.
            // Re-read and verify it immediately before any checkout so the
            // pull-only path never switches or updates a different branch.
            let actualBranch = git_reference_shorthand(head).map { String(cString: $0) } ?? "HEAD"
            guard actualBranch == branch else {
                throw LocalGitError.wrongBranch(expected: branch, actual: actualBranch)
            }

            let localOidPtr = git_reference_target(head)!
            let remoteOidPtr = git_reference_target(remoteRef)!
            var expectedLocalOid = localOidPtr.pointee

            if git_oid_equal(localOidPtr, remoteOidPtr) != 0 {
                return (result: LocalPullResult(updated: false, newCommitSHA: oidToHex(localOidPtr)), changedPaths: [String]())
            }

            // The repository may be modified by another process between the
            // earlier plan and this mutation phase. Classify these freshly-read
            // OIDs and refuse anything except a true clean fast-forward.
            var ahead = 0
            var behind = 0
            try git2Check(
                git_graph_ahead_behind(&ahead, &behind, repo, localOidPtr, remoteOidPtr),
                context: "Revalidate fast-forward relation"
            )
            guard ahead == 0, behind > 0 else {
                throw LocalGitError.pullDiverged
            }

            let changedPaths = try Self.changedPathsBetween(repo: repo, oldOID: localOidPtr, newOID: remoteOidPtr)

            var remoteOidCopy = remoteOidPtr.pointee
            var remoteCommit: OpaquePointer?
            defer { if let remoteCommit { git_commit_free(remoteCommit) } }
            try git2Check(
                git_commit_lookup(&remoteCommit, repo, &remoteOidCopy),
                context: "Lookup remote commit"
            )

            var remoteTree: OpaquePointer?
            defer { if let remoteTree { git_tree_free(remoteTree) } }
            try git2Check(git_commit_tree(&remoteTree, remoteCommit), context: "Get remote tree")

            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            // Re-read immediately before checkout. Another process or Files
            // provider may have changed the worktree since planning or the
            // earlier guard; automation must fail closed rather than overwrite.
            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.pullBlockedByLocalChanges
            }
            if isPullOnly { pullOnlyBeforeCheckout?() }

            // Hold both HEAD and the checked-out branch ref from the final OID
            // validation through checkout/index mutation and the ref commit.
            // This prevents another Git process from advancing the branch after
            // ancestry validation and having automation overwrite its commit.
            let localRefName = "refs/heads/\(branch)"
            var refTransaction: OpaquePointer?
            defer { if let refTransaction { git_transaction_free(refTransaction) } }
            try git2Check(git_transaction_new(&refTransaction, repo), context: "Create fast-forward ref transaction")
            try git2Check(git_transaction_lock_ref(refTransaction, "HEAD"), context: "Lock HEAD for fast-forward")
            try git2Check(git_transaction_lock_ref(refTransaction, localRefName), context: "Lock branch for fast-forward")

            var lockedHead: OpaquePointer?
            defer { if let lockedHead { git_reference_free(lockedHead) } }
            try git2Check(git_repository_head(&lockedHead, repo), context: "Re-read locked HEAD")
            let lockedBranch = git_reference_shorthand(lockedHead).map { String(cString: $0) } ?? "HEAD"
            guard lockedBranch == branch else {
                throw LocalGitError.wrongBranch(expected: branch, actual: lockedBranch)
            }
            guard let lockedLocalOid = git_reference_target(lockedHead),
                  git_oid_equal(lockedLocalOid, &expectedLocalOid) != 0 else {
                throw LocalGitError.pullDiverged
            }

            let checkoutCode = git_checkout_tree(repo, remoteTree, &checkoutOpts)
            if checkoutCode == GIT_ECONFLICT.rawValue {
                // Never force a background/pull-only checkout. A conflict may
                // be a real local write created after the last status read;
                // preserving user bytes is more important than normalisation
                // recovery, which remains a manual foreground concern.
                throw LocalGitError.pullBlockedByLocalChanges
            }
            try git2Check(checkoutCode, context: "Checkout remote tree safely")

            // Explicitly rebuild the index from the remote tree and flush it
            // to disk. git_checkout_tree is supposed to update index entries
            // as it walks files, but relying on that leaves a window where a
            // freshly-added file pulled from the remote can still appear as
            // untracked in subsequent status reads — the working tree has the
            // file while the on-disk index never recorded it. Re-reading the
            // remote tree into the index and writing it guarantees HEAD ==
            // index == workdir after a fast-forward pull.
            var pulledIndex: OpaquePointer?
            defer { if let pulledIndex { git_index_free(pulledIndex) } }
            try git2Check(
                git_repository_index(&pulledIndex, repo),
                context: "Open index after fast-forward checkout"
            )
            try git2Check(
                git_index_read_tree(pulledIndex, remoteTree),
                context: "Rebuild index from remote tree"
            )
            try git2Check(
                git_index_write(pulledIndex),
                context: "Write index after fast-forward"
            )

            try git2Check(
                git_transaction_set_target(refTransaction, localRefName, &remoteOidCopy, nil, "pull: fast-forward"),
                context: "Queue branch ref update"
            )
            try git2Check(git_transaction_commit(refTransaction), context: "Commit branch ref update")
            try Self.recordReceivedFiles(repo: repo, before: &expectedLocalOid, after: remoteOidPtr)

            return (result: LocalPullResult(updated: true, newCommitSHA: oidToHex(&remoteOidCopy)), changedPaths: changedPaths)
        }.value

        if fastForward.result.updated {
            let lfsResult = try await Self.hydrateLFSIfNeeded(
                localURL: localURL,
                pat: pat,
                candidatePaths: fastForward.changedPaths
            )
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Hydrated Git LFS files after pull", detail: "\(lfsResult.checkedOutCount) files")
            }
        }

        return fastForward.result
    }

    private func performRebaseOntoOrigin(
        branch: String,
        pat: String,
        authorName: String,
        authorEmail: String,
        refetch: Bool
    ) async throws -> LocalPullResult {
        let path = self.localURL.path
        let localURL = self.localURL

        let rebaseResult = try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")

            Self.setPrecomposeUnicode(repo: repo)

            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.pullBlockedByLocalChanges
            }

            if refetch {
                try Self.fetchOrigin(repo: repo, pat: pat)
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")

            guard let oldHeadOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for rebase"))
            }
            var oldHeadOidCopy = oldHeadOid.pointee

            let remoteRefName = "refs/remotes/origin/\(branch)"
            var remoteRef: OpaquePointer?
            defer { if let remoteRef { git_reference_free(remoteRef) } }
            let remoteLookupCode = git_reference_lookup(&remoteRef, repo, remoteRefName)
            if remoteLookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.pullRemoteBranchMissing(branch)
            }
            try git2Check(remoteLookupCode, context: "Lookup \(remoteRefName)")

            guard let remoteOid = git_reference_target(remoteRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve remote branch target for rebase"))
            }

            if git_oid_equal(&oldHeadOidCopy, remoteOid) != 0 {
                return (result: LocalPullResult(updated: false, newCommitSHA: oidToHex(&oldHeadOidCopy)), changedPaths: [String]())
            }

            var ahead: Int = 0
            var behind: Int = 0
            try git2Check(
                git_graph_ahead_behind(&ahead, &behind, repo, &oldHeadOidCopy, remoteOid),
                context: "Compute ahead/behind for rebase"
            )

            if ahead == 0 && behind > 0 {
                // This explicit rebase action should still use the safer and
                // simpler fast-forward path when no local commits need replaying.
                throw LocalGitError.libgit2(String(localized: "Internal error: rebase requested for a fast-forward pull"))
            }
            if behind == 0 {
                return (result: LocalPullResult(updated: false, newCommitSHA: oidToHex(&oldHeadOidCopy)), changedPaths: [String]())
            }

            var annotatedRemote: OpaquePointer?
            defer { if let annotatedRemote { git_annotated_commit_free(annotatedRemote) } }
            try git2Check(
                git_annotated_commit_from_ref(&annotatedRemote, repo, remoteRef),
                context: "Create annotated remote commit for rebase"
            )

            var rebaseOpts = git_rebase_options()
            git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))
            rebaseOpts.merge_options.flags = UInt32(GIT_MERGE_FIND_RENAMES.rawValue)
            rebaseOpts.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            var rebase: OpaquePointer?
            defer { if let rebase { git_rebase_free(rebase) } }
            try git2Check(
                git_rebase_init(&rebase, repo, nil, annotatedRemote, annotatedRemote, &rebaseOpts),
                context: "Start rebase"
            )

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            try Self.advanceRebase(repo: repo, rebase: rebase, signature: signature)

            var newHeadRef: OpaquePointer?
            defer { if let newHeadRef { git_reference_free(newHeadRef) } }
            try git2Check(git_repository_head(&newHeadRef, repo), context: "Read rebased HEAD")
            guard let newHeadOid = git_reference_target(newHeadRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve rebased HEAD"))
            }

            let changedPaths = try Self.changedPathsBetween(repo: repo, oldOID: &oldHeadOidCopy, newOID: newHeadOid)
            return (result: LocalPullResult(updated: true, newCommitSHA: oidToHex(newHeadOid)), changedPaths: changedPaths)
        }.value

        if rebaseResult.result.updated {
            let lfsResult = try await Self.hydrateLFSIfNeeded(
                localURL: localURL,
                pat: pat,
                candidatePaths: rebaseResult.changedPaths
            )
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Hydrated Git LFS files after rebase", detail: "\(lfsResult.checkedOutCount) files")
            }
        }

        return rebaseResult.result
    }

    // MARK: - Git LFS History Repair

    /// Converts large ordinary blobs inside strictly-unpushed commits into Git
    /// LFS pointers by rewriting only the local-only commit range.
    ///
    /// Safety model:
    /// - Fetches first, then refuses conflict sessions, dirty trees, detached
    ///   HEAD, missing upstream branches, divergence, and merge commits.
    /// - Only commits after the origin merge base are rebuilt; commits
    ///   reachable from the remote are never rewritten. LFS objects are uploaded
    ///   before the branch moves, but the Git branch itself is not pushed here.
    /// - New blobs/trees/commits are written side by side; the only history
    ///   mutation is a single compare-and-swap branch-ref update after a durable
    ///   backup exists. Cancellation is honored before that point. Synchronous
    ///   failures during the final index/worktree bookkeeping roll the ref back,
    ///   and the original tip always remains reachable from the backup ref.
    /// - Author, committer, message, and file modes of every rewritten commit
    ///   are preserved — nothing is squashed. Working-tree files are untouched
    ///   except .gitattributes, which gains the new tracking rules.
    func repairUnpushedLargeBlobs(pat: String) async throws -> GitLFSRepairResult {
        let repoPath = self.localURL.path
        let repositoryURL = self.localURL
        let gitLFSServiceFactory = self.gitLFSServiceFactory

        // A detached task has its own cancellation state, so the caller's
        // cancellation is forwarded explicitly; the checkCancellation calls
        // inside then take effect at the safe points between phases.
        let work = Task.detached { () -> GitLFSRepairResult in
            try Task.checkCancellation()
            let policy = GitLFSAutoTrackingPolicy.default

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")
            Self.setPrecomposeUnicode(repo: repo)

            // Refuse anything but a quiet repository sitting on a branch.
            guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else {
                throw LocalGitError.lfsRepairBlocked(.conflictSessionActive)
            }
            guard git_repository_head_detached(repo) == 0 else {
                throw LocalGitError.lfsRepairBlocked(.detachedHead)
            }
            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.lfsRepairBlocked(.dirtyWorkingTree)
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")
            guard let localOidPtr = git_reference_target(headRef),
                  let branchName = git_reference_shorthand(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for LFS repair"))
            }
            var localOid = localOidPtr.pointee
            let branch = String(cString: branchName)
            let localSHA = oidToHex(&localOid)

            // The unpushed range is defined against the remote's actual state.
            try Self.fetchOrigin(repo: repo, pat: pat)
            try Task.checkCancellation()

            let remoteRefName = "refs/remotes/origin/\(branch)"
            var remoteRef: OpaquePointer?
            defer { if let remoteRef { git_reference_free(remoteRef) } }
            let remoteLookupCode = git_reference_lookup(&remoteRef, repo, remoteRefName)
            if remoteLookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.lfsRepairBlocked(.remoteBranchMissing(branch))
            }
            try git2Check(remoteLookupCode, context: "Lookup \(remoteRefName)")
            guard let remoteOidPtr = git_reference_target(remoteRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve \(remoteRefName)"))
            }
            var remoteOid = remoteOidPtr.pointee

            var ahead = 0
            var behind = 0
            try git2Check(
                git_graph_ahead_behind(&ahead, &behind, repo, &localOid, &remoteOid),
                context: "Compute ahead/behind for LFS repair"
            )
            guard behind == 0 else {
                throw LocalGitError.lfsRepairBlocked(.diverged(behindBy: behind))
            }
            if ahead == 0 {
                return GitLFSRepairResult(
                    outcome: .nothingToRepair, rewrittenCommitCount: 0, convertedPaths: [],
                    convertedByteCount: 0, backupRefName: nil, newHeadSHA: localSHA
                )
            }
            var mergeBase = git_oid()
            try git2Check(
                git_merge_base(&mergeBase, repo, &localOid, &remoteOid),
                context: "Compute merge base for LFS repair"
            )
            guard git_oid_equal(&mergeBase, &remoteOid) != 0 else {
                throw LocalGitError.lfsRepairBlocked(.diverged(behindBy: behind))
            }

            // Collect the ahead-only commits, oldest first.
            var walk: OpaquePointer?
            defer { if let walk { git_revwalk_free(walk) } }
            try git2Check(git_revwalk_new(&walk, repo), context: "Create revwalk for LFS repair")
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_REVERSE.rawValue)
            try git2Check(git_revwalk_push(walk, &localOid), context: "Walk local commits")
            try git2Check(git_revwalk_hide(walk, &remoteOid), context: "Hide remote-reachable commits")
            var aheadOids: [git_oid] = []
            var walkOid = git_oid()
            while git_revwalk_next(&walkOid, walk) == 0 {
                aheadOids.append(walkOid)
            }

            var odb: OpaquePointer?
            defer { if let odb { git_odb_free(odb) } }
            try git2Check(git_repository_odb(&odb, repo), context: "Open object database")

            // Find offending blobs introduced by each ahead commit. Blobs that
            // are unchanged relative to the merge base never appear in these
            // diffs, so remote-reachable content is naturally left alone.
            struct Offender {
                let path: String
                var blobOid: git_oid
                let modeRaw: UInt16
                let size: Int64
            }
            var offendersByCommit: [String: [Offender]] = [:]
            var uniqueBlobSizes: [String: Int64] = [:]
            var orderedConvertedPaths: [String] = []
            var seenPaths = Set<String>()

            for var commitOid in aheadOids {
                var commit: OpaquePointer?
                defer { if let commit { git_commit_free(commit) } }
                try git2Check(git_commit_lookup(&commit, repo, &commitOid), context: "Lookup unpushed commit")
                guard git_commit_parentcount(commit) == 1 else {
                    var oidCopy = commitOid
                    throw LocalGitError.lfsRepairBlocked(.mergeCommitInUnpushedRange(oidToHex(&oidCopy)))
                }
                var parent: OpaquePointer?
                defer { if let parent { git_commit_free(parent) } }
                try git2Check(git_commit_parent(&parent, commit, 0), context: "Lookup parent of unpushed commit")
                var parentTree: OpaquePointer?
                defer { if let parentTree { git_tree_free(parentTree) } }
                try git2Check(git_commit_tree(&parentTree, parent), context: "Read parent tree")
                var tree: OpaquePointer?
                defer { if let tree { git_tree_free(tree) } }
                try git2Check(git_commit_tree(&tree, commit), context: "Read commit tree")
                var diff: OpaquePointer?
                defer { if let diff { git_diff_free(diff) } }
                try git2Check(git_diff_tree_to_tree(&diff, repo, parentTree, tree, nil), context: "Diff unpushed commit")

                var commitOffenders: [Offender] = []
                for i in 0..<Int(git_diff_num_deltas(diff)) {
                    guard let delta = git_diff_get_delta(diff, i)?.pointee,
                          delta.status != GIT_DELTA_DELETED,
                          delta.new_file.mode == UInt16(GIT_FILEMODE_BLOB.rawValue)
                            || delta.new_file.mode == UInt16(GIT_FILEMODE_BLOB_EXECUTABLE.rawValue),
                          let pathPtr = delta.new_file.path else { continue }
                    let path = String(cString: pathPtr)
                    var blobOid = delta.new_file.id
                    var size: size_t = 0
                    var objectType = GIT_OBJECT_INVALID
                    guard git_odb_read_header(&size, &objectType, odb, &blobOid) == 0,
                          objectType == GIT_OBJECT_BLOB else { continue }
                    let blobSize = Int64(size)
                    // Same criterion that blocks the push: a blob this large can
                    // never be a valid pointer file, so no pointer parse needed.
                    guard blobSize > policy.largeFileThresholdBytes else { continue }
                    commitOffenders.append(Offender(path: path, blobOid: blobOid, modeRaw: delta.new_file.mode, size: blobSize))
                    var blobOidCopy = blobOid
                    uniqueBlobSizes[oidToHex(&blobOidCopy)] = blobSize
                    if seenPaths.insert(path).inserted {
                        orderedConvertedPaths.append(path)
                    }
                }
                if !commitOffenders.isEmpty {
                    var oidCopy = commitOid
                    offendersByCommit[oidToHex(&oidCopy)] = commitOffenders
                }
            }

            if uniqueBlobSizes.isEmpty {
                return GitLFSRepairResult(
                    outcome: .nothingToRepair, rewrittenCommitCount: 0, convertedPaths: [],
                    convertedByteCount: 0, backupRefName: nil, newHeadSHA: localSHA
                )
            }

            // Preflight disk space: each offending blob is copied once into
            // .git/lfs/objects so the later push can upload it.
            let requiredBytes = uniqueBlobSizes.values.reduce(Int64(0), +)
            if let available = (try? repositoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage,
               available < requiredBytes + 200 * 1024 * 1024 {
                throw LocalGitError.lfsRepairBlocked(.insufficientDiskSpace(requiredBytes: requiredBytes, availableBytes: available))
            }

            // Durable backup ref to the original tip, created before anything
            // else is written.
            let stampFormatter = DateFormatter()
            stampFormatter.locale = Locale(identifier: "en_US_POSIX")
            stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
            var backupRefName = "refs/vaultbridge/lfs-repair/\(stampFormatter.string(from: Date()))-\(String(localSHA.prefix(12)))"
            var backupRef: OpaquePointer?
            defer { if let backupRef { git_reference_free(backupRef) } }
            var backupCode = backupRefName.withCString {
                git_reference_create(&backupRef, repo, $0, &localOid, 0, "vaultbridge: LFS repair backup")
            }
            if backupCode == GIT_EEXISTS.rawValue {
                backupRefName += "-\(UUID().uuidString.prefix(8).lowercased())"
                backupCode = backupRefName.withCString {
                    git_reference_create(&backupRef, repo, $0, &localOid, 0, "vaultbridge: LFS repair backup")
                }
            }
            try git2Check(backupCode, context: "Create LFS repair backup ref")

            // Materialize every offending blob into LFS object storage and
            // compute its pointer. Streamed in chunks; large media never has to
            // fit in memory.
            var pointerByBlobHex: [String: GitLFSPointer] = [:]
            let tmpDir = repositoryURL.appendingPathComponent(".git/lfs/tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            for blobHex in uniqueBlobSizes.keys.sorted() {
                try Task.checkCancellation()
                var blobOid = git_oid()
                _ = blobHex.withCString { git_oid_fromstr(&blobOid, $0) }
                let tmpURL = tmpDir.appendingPathComponent("repair-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tmpURL) }
                try Self.streamBlob(odb: odb, oid: &blobOid, to: tmpURL)
                let info = try GitLFSPointer.sha256HexAndSize(forFileAt: tmpURL)
                let pointer = GitLFSPointer(oid: info.oid, size: info.size)
                let objectURL = GitLFSService.objectStorageURL(oid: pointer.oid, repositoryURL: repositoryURL)
                if !FileManager.default.fileExists(atPath: objectURL.path) {
                    try FileManager.default.createDirectory(at: objectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: tmpURL, to: objectURL)
                }
                pointerByBlobHex[blobHex] = pointer
            }

            // Upload every object referenced anywhere in the rewritten range,
            // not only pointers visible in the final tree. A file can be added
            // in one unpushed commit and deleted or replaced in the next; that
            // intermediate commit must still remain fully checkoutable after
            // the Git commits are pushed.
            try Task.checkCancellation()
            let lfsService = gitLFSServiceFactory(
                repositoryURL,
                GitRemoteCredentials.fromTransportPayload(pat)
            )
            try await lfsService.verifyPushAllowed(
                changedPaths: orderedConvertedPaths,
                refName: "refs/heads/\(branch)"
            )
            let repairPointers = Array(Set(pointerByBlobHex.values))
            let uploadedCount = try await lfsService.uploadObjects(repairPointers)
            DebugLogger.shared.info(
                "lfs",
                "Uploaded Git LFS objects for history repair",
                detail: "\(uploadedCount) uploaded, \(repairPointers.count) referenced across rewritten commits"
            )
            try Task.checkCancellation()

            // Rebuild the ahead-only chain oldest → newest, preserving author,
            // committer, message, and file modes.
            var newParentOid = remoteOid
            var runningPatterns: [String] = []
            var convertedPathsSoFar: Set<String> = []
            var rewrittenCount = 0

            for var commitOid in aheadOids {
                var commit: OpaquePointer?
                defer { if let commit { git_commit_free(commit) } }
                try git2Check(git_commit_lookup(&commit, repo, &commitOid), context: "Lookup commit for rewrite")
                var tree: OpaquePointer?
                defer { if let tree { git_tree_free(tree) } }
                try git2Check(git_commit_tree(&tree, commit), context: "Read tree for rewrite")

                var commitOidCopy = commitOid
                let offenders = offendersByCommit[oidToHex(&commitOidCopy)] ?? []
                for offender in offenders {
                    convertedPathsSoFar.insert(offender.path)
                    for pattern in policy.repairPatterns(forPath: offender.path) where !runningPatterns.contains(pattern) {
                        runningPatterns.append(pattern)
                    }
                }

                var updates: [git_tree_update] = []
                var retainedPaths: [UnsafeMutablePointer<CChar>] = []
                defer { retainedPaths.forEach { free($0) } }

                // A converted blob usually persists unchanged through later
                // commits, where it no longer appears in any diff — so every
                // tree in the range is checked for every converted path. The
                // pointer map only contains offending blobs, which makes the
                // lookup a precise "is this still the large ordinary blob"
                // test: deleted paths and small replacements fall through.
                for path in convertedPathsSoFar.sorted() {
                    var treeEntry: OpaquePointer?
                    let found = path.withCString { git_tree_entry_bypath(&treeEntry, tree, $0) } == 0
                    defer { if let treeEntry { git_tree_entry_free(treeEntry) } }
                    guard found, let treeEntry,
                          git_tree_entry_type(treeEntry) == GIT_OBJECT_BLOB,
                          let entryOidPtr = git_tree_entry_id(treeEntry) else { continue }
                    var entryOid = entryOidPtr.pointee
                    guard let pointer = pointerByBlobHex[oidToHex(&entryOid)] else { continue }

                    let pointerData = Data(pointer.serializedString.utf8)
                    var pointerBlobOid = git_oid()
                    try pointerData.withUnsafeBytes { raw in
                        try git2Check(
                            git_blob_create_from_buffer(&pointerBlobOid, repo, raw.baseAddress, pointerData.count),
                            context: "Write LFS pointer blob"
                        )
                    }
                    var update = git_tree_update()
                    update.action = GIT_TREE_UPDATE_UPSERT
                    update.id = pointerBlobOid
                    update.filemode = git_tree_entry_filemode(treeEntry)
                    let cPath = strdup(path)!
                    retainedPaths.append(cPath)
                    update.path = UnsafePointer(cPath)
                    updates.append(update)
                }

                if !runningPatterns.isEmpty {
                    let existingText = Self.treeBlobText(repo: repo, tree: tree, path: ".gitattributes") ?? ""
                    if let updatedText = GitLFSService.attributesTextAppendingLFSRules(existingText, patterns: runningPatterns) {
                        let data = Data(updatedText.utf8)
                        var attrsOid = git_oid()
                        try data.withUnsafeBytes { raw in
                            try git2Check(
                                git_blob_create_from_buffer(&attrsOid, repo, raw.baseAddress, data.count),
                                context: "Write .gitattributes blob"
                            )
                        }
                        var update = git_tree_update()
                        update.action = GIT_TREE_UPDATE_UPSERT
                        update.id = attrsOid
                        update.filemode = GIT_FILEMODE_BLOB
                        let cPath = strdup(".gitattributes")!
                        retainedPaths.append(cPath)
                        update.path = UnsafePointer(cPath)
                        updates.append(update)
                    }
                }

                var newTreeOid = git_oid()
                if updates.isEmpty {
                    newTreeOid = git_tree_id(tree).pointee
                } else {
                    try updates.withUnsafeBufferPointer { buf in
                        try git2Check(
                            git_tree_create_updated(&newTreeOid, repo, tree, buf.count, buf.baseAddress),
                            context: "Rebuild tree with LFS pointers"
                        )
                    }
                }

                var newTree: OpaquePointer?
                defer { if let newTree { git_tree_free(newTree) } }
                try git2Check(git_tree_lookup(&newTree, repo, &newTreeOid), context: "Lookup rebuilt tree")
                var parentCommit: OpaquePointer?
                defer { if let parentCommit { git_commit_free(parentCommit) } }
                try git2Check(git_commit_lookup(&parentCommit, repo, &newParentOid), context: "Lookup rewritten parent")

                var newCommitOid = git_oid()
                var parents: [OpaquePointer?] = [parentCommit]
                try parents.withUnsafeMutableBufferPointer { buf in
                    try git2Check(
                        git_commit_create(
                            &newCommitOid, repo, nil,
                            git_commit_author(commit), git_commit_committer(commit),
                            git_commit_message_encoding(commit), git_commit_message_raw(commit),
                            newTree, 1, buf.baseAddress
                        ),
                        context: "Rewrite unpushed commit"
                    )
                }
                newParentOid = newCommitOid
                rewrittenCount += 1
            }

            // The single mutation of shared state: compare-and-swap the branch
            // to the repaired chain. From here on the finishing steps are local
            // bookkeeping and are intentionally not cancellable. If synchronous
            // bookkeeping fails, the branch and worktree attributes are rolled
            // back; the durable repair backup remains either way.
            guard let branchRefName = git_reference_name(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve branch ref for LFS repair"))
            }
            let attributesURL = repositoryURL.appendingPathComponent(".gitattributes")
            let attributesExistedBeforeRepair = FileManager.default.fileExists(atPath: attributesURL.path)
            let originalAttributesData = attributesExistedBeforeRepair ? try Data(contentsOf: attributesURL) : nil
            var updatedRef: OpaquePointer?
            defer { if let updatedRef { git_reference_free(updatedRef) } }
            let updateCode = git_reference_create_matching(
                &updatedRef,
                repo,
                branchRefName,
                &newParentOid,
                1,
                &localOid,
                "vaultbridge: git lfs repair"
            )
            if updateCode == GIT_EMODIFIED.rawValue {
                throw LocalGitError.lfsRepairBlocked(.branchChangedDuringRepair)
            }
            try git2Check(updateCode, context: "Update branch to repaired commits")

            do {
                var newTipCommit: OpaquePointer?
                defer { if let newTipCommit { git_commit_free(newTipCommit) } }
                try git2Check(git_commit_lookup(&newTipCommit, repo, &newParentOid), context: "Lookup repaired tip")
                var finalTree: OpaquePointer?
                defer { if let finalTree { git_tree_free(finalTree) } }
                try git2Check(git_commit_tree(&finalTree, newTipCommit), context: "Read repaired tip tree")

                var index: OpaquePointer?
                defer { if let index { git_index_free(index) } }
                try git2Check(git_repository_index(&index, repo), context: "Open index after LFS repair")

                // Update only the affected index entries so the stat cache of
                // every other file survives; then keep worktree attributes in
                // line with the rewritten tip.
                var cleanRecords: [(path: String, pointer: GitLFSPointer)] = []
                for path in orderedConvertedPaths {
                    var treeEntry: OpaquePointer?
                    let found = path.withCString { git_tree_entry_bypath(&treeEntry, finalTree, $0) } == 0
                    defer { if let treeEntry { git_tree_entry_free(treeEntry) } }
                    guard found, let treeEntry, let entryOid = git_tree_entry_id(treeEntry) else { continue }
                    var blobOid = entryOid.pointee
                    var blob: OpaquePointer?
                    defer { if let blob { git_blob_free(blob) } }
                    guard git_blob_lookup(&blob, repo, &blobOid) == 0, let blob else { continue }
                    let size = Int(git_blob_rawsize(blob))
                    guard size > 0, size <= 2048, let raw = git_blob_rawcontent(blob),
                          let pointer = GitLFSPointer(data: Data(bytes: raw, count: size)) else { continue }
                    try GitLFSService.addPointer(pointer, path: path, to: index)
                    if FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(path).path) {
                        cleanRecords.append((path: path, pointer: pointer))
                    }
                }

                if let attrsText = Self.treeBlobText(repo: repo, tree: finalTree, path: ".gitattributes") {
                    try attrsText.write(to: attributesURL, atomically: true, encoding: .utf8)
                    try git2Check(
                        ".gitattributes".withCString { git_index_add_bypath(index, $0) },
                        context: "Update .gitattributes in index after LFS repair"
                    )
                }
                try git2Check(git_index_write(index), context: "Write index after LFS repair")
                GitLFSService.markFilesKnownClean(repositoryURL: repositoryURL, files: cleanRecords)
            } catch {
                // git_index_write uses its own lockfile, so an error leaves the
                // on-disk index unchanged. Restore the only worktree file this
                // repair can touch, then move the branch back only if it still
                // points at our repaired tip.
                if let originalAttributesData {
                    try? originalAttributesData.write(to: attributesURL, options: .atomic)
                } else if !attributesExistedBeforeRepair {
                    try? FileManager.default.removeItem(at: attributesURL)
                }

                var rolledBackRef: OpaquePointer?
                defer { if let rolledBackRef { git_reference_free(rolledBackRef) } }
                let rollbackCode = git_reference_create_matching(
                    &rolledBackRef,
                    repo,
                    branchRefName,
                    &localOid,
                    1,
                    &newParentOid,
                    "vaultbridge: roll back incomplete git lfs repair"
                )
                if rollbackCode != 0 {
                    throw LocalGitError.repositoryCorrupted(
                        String(localized: "LFS history was repaired, but local index bookkeeping failed and the branch could not be rolled back. Your original tip remains safe at \(backupRefName). Details: \(error.localizedDescription)")
                    )
                }
                throw error
            }

            var tipOid = newParentOid
            return GitLFSRepairResult(
                outcome: .repaired,
                rewrittenCommitCount: rewrittenCount,
                convertedPaths: orderedConvertedPaths,
                convertedByteCount: requiredBytes,
                backupRefName: backupRefName,
                newHeadSHA: oidToHex(&tipOid)
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Streams a blob out of the object database into a file in fixed-size
    /// chunks so multi-gigabyte media never has to fit in memory.
    private static func streamBlob(odb: OpaquePointer?, oid: inout git_oid, to fileURL: URL) throws {
        var stream: UnsafeMutablePointer<git_odb_stream>?
        var length: size_t = 0
        var objectType = GIT_OBJECT_INVALID
        try git2Check(
            git_odb_open_rstream(&stream, &length, &objectType, odb, &oid),
            context: "Open blob stream for LFS repair"
        )
        defer { git_odb_stream_free(stream) }

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let bufferSize = 4 * 1024 * 1024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var remaining = Int(length)
        while remaining > 0 {
            let read = Int(buffer.withUnsafeMutableBufferPointer { buf in
                git_odb_stream_read(stream, buf.baseAddress, min(bufferSize, remaining))
            })
            if read < 0 {
                try git2Check(Int32(read), context: "Read blob stream for LFS repair")
            }
            if read == 0 { break }
            try buffer.withUnsafeBufferPointer { buf in
                try buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: read) { bytes in
                    try handle.write(contentsOf: Data(bytes: bytes, count: read))
                }
            }
            remaining -= read
        }
        guard remaining == 0 else {
            throw LocalGitError.lfsFailed(String(localized: "Blob stream ended early during LFS repair."))
        }
    }

    private static func treeBlobText(repo: OpaquePointer?, tree: OpaquePointer?, path: String) -> String? {
        var entry: OpaquePointer?
        let code = path.withCString { git_tree_entry_bypath(&entry, tree, $0) }
        guard code == 0, let entry else { return nil }
        defer { git_tree_entry_free(entry) }
        guard let oidPtr = git_tree_entry_id(entry) else { return nil }
        var oid = oidPtr.pointee
        var blob: OpaquePointer?
        defer { if let blob { git_blob_free(blob) } }
        guard git_blob_lookup(&blob, repo, &oid) == 0, let blob else { return nil }
        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let raw = git_blob_rawcontent(blob) else { return "" }
        return String(data: Data(bytes: raw, count: size), encoding: .utf8)
    }

    // MARK: - Branches

    func listBranches() async throws -> BranchInventory {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            let isDetached = git_repository_head_detached(repo) == 1
            var detachedHeadOID: String? = nil
            var currentBranchShortName: String? = nil

            if isDetached {
                var headRef: OpaquePointer?
                defer { if let headRef { git_reference_free(headRef) } }
                if git_repository_head(&headRef, repo) == 0,
                   let oid = git_reference_target(headRef) {
                    detachedHeadOID = oidToHex(oid)
                }
            } else {
                var headRef: OpaquePointer?
                defer { if let headRef { git_reference_free(headRef) } }
                if git_repository_head(&headRef, repo) == 0,
                   let shorthand = git_reference_shorthand(headRef) {
                    currentBranchShortName = String(cString: shorthand)
                }
            }

            var iterator: OpaquePointer?
            defer { if let iterator { git_branch_iterator_free(iterator) } }
            try git2Check(
                git_branch_iterator_new(&iterator, repo, GIT_BRANCH_ALL),
                context: "Create branch iterator"
            )

            var localBranches: [GitBranchInfo] = []
            var remoteBranches: [GitBranchInfo] = []

            while true {
                var ref: OpaquePointer?
                var branchType = GIT_BRANCH_LOCAL
                let nextCode = git_branch_next(&ref, &branchType, iterator)

                if nextCode == GIT_ITEROVER.rawValue {
                    break
                }

                try git2Check(nextCode, context: "Iterate branches")
                guard let ref else { continue }
                defer { git_reference_free(ref) }

                guard let namePtr = git_reference_name(ref),
                      let shortNamePtr = git_reference_shorthand(ref) else {
                    continue
                }

                let fullName = String(cString: namePtr)
                let shortName = String(cString: shortNamePtr)

                if branchType == GIT_BRANCH_REMOTE && shortName.hasSuffix("/HEAD") {
                    continue
                }

                let scope: GitBranchScope = (branchType == GIT_BRANCH_REMOTE) ? .remote : .local
                let isCurrent = scope == .local && shortName == currentBranchShortName

                var upstreamShortName: String? = nil
                var aheadBy: Int? = nil
                var behindBy: Int? = nil

                if scope == .local {
                    var upstreamRef: OpaquePointer?
                    defer { if let upstreamRef { git_reference_free(upstreamRef) } }

                    let upstreamCode = git_branch_upstream(&upstreamRef, ref)
                    if upstreamCode == 0, let upstreamRef {
                        if let upstreamShorthand = git_reference_shorthand(upstreamRef) {
                            upstreamShortName = String(cString: upstreamShorthand)
                        }

                        if let localOID = git_reference_target(ref),
                           let upstreamOID = git_reference_target(upstreamRef) {
                            var ahead = 0
                            var behind = 0
                            if git_graph_ahead_behind(&ahead, &behind, repo, localOID, upstreamOID) == 0 {
                                aheadBy = ahead
                                behindBy = behind
                            }
                        }
                    } else if upstreamCode != GIT_ENOTFOUND.rawValue {
                        try git2Check(upstreamCode, context: "Read branch upstream")
                    }
                }

                let info = GitBranchInfo(
                    name: fullName,
                    shortName: shortName,
                    scope: scope,
                    isCurrent: isCurrent,
                    upstreamShortName: upstreamShortName,
                    aheadBy: aheadBy,
                    behindBy: behindBy
                )

                if scope == .local {
                    localBranches.append(info)
                } else {
                    remoteBranches.append(info)
                }
            }

            localBranches.sort { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
            remoteBranches.sort { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }

            return BranchInventory(local: localBranches, remote: remoteBranches, detachedHeadOID: detachedHeadOID)
        }.value
    }

    func createBranch(name: String) async throws {
        let repoPath = self.localURL.path
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !branchName.isEmpty else {
            throw LocalGitError.branchNotFound(name)
        }

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var existing: OpaquePointer?
            defer { if let existing { git_reference_free(existing) } }
            let lookupCode = git_branch_lookup(&existing, repo, branchName, GIT_BRANCH_LOCAL)
            if lookupCode == 0 {
                throw LocalGitError.branchAlreadyExists(branchName)
            }
            if lookupCode != GIT_ENOTFOUND.rawValue {
                try git2Check(lookupCode, context: "Lookup branch \(branchName)")
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")
            guard let headOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD target while creating branch"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOidCopy = headOid.pointee
            try git2Check(
                git_commit_lookup(&headCommit, repo, &headOidCopy),
                context: "Lookup HEAD commit"
            )

            var newBranchRef: OpaquePointer?
            defer { if let newBranchRef { git_reference_free(newBranchRef) } }
            try branchName.withCString { cName in
                try git2Check(
                    git_branch_create(&newBranchRef, repo, cName, headCommit, 0),
                    context: "Create branch \(branchName)"
                )
            }
        }.value
    }

    func switchBranch(name: String) async throws {
        let repoPath = self.localURL.path
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.checkoutBlockedByLocalChanges
            }

            var branchRef: OpaquePointer?
            defer { if let branchRef { git_reference_free(branchRef) } }
            let lookupCode = git_branch_lookup(&branchRef, repo, branchName, GIT_BRANCH_LOCAL)
            if lookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.branchNotFound(branchName)
            }
            try git2Check(lookupCode, context: "Lookup branch \(branchName)")

            var targetObject: OpaquePointer?
            defer { if let targetObject { git_object_free(targetObject) } }
            try git2Check(
                git_reference_peel(&targetObject, branchRef, GIT_OBJECT_COMMIT),
                context: "Resolve branch target \(branchName)"
            )

            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            try git2Check(
                git_checkout_tree(repo, targetObject, &checkoutOpts),
                context: "Checkout branch tree \(branchName)"
            )

            guard let fullRefName = git_reference_name(branchRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not read branch ref name for \(branchName)"))
            }
            try git2Check(git_repository_set_head(repo, fullRefName), context: "Set HEAD to \(branchName)")
        }.value
    }

    func deleteBranch(name: String) async throws {
        let repoPath = self.localURL.path
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var branchRef: OpaquePointer?
            defer { if let branchRef { git_reference_free(branchRef) } }
            let lookupCode = git_branch_lookup(&branchRef, repo, branchName, GIT_BRANCH_LOCAL)
            if lookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.branchNotFound(branchName)
            }
            try git2Check(lookupCode, context: "Lookup branch \(branchName)")

            if git_branch_is_head(branchRef) == 1 {
                throw LocalGitError.branchIsCurrent(branchName)
            }

            try git2Check(git_branch_delete(branchRef), context: "Delete branch \(branchName)")
        }.value
    }

    func mergeBranch(name: String, authorName: String, authorEmail: String) async throws -> MergeResult {
        let repoPath = self.localURL.path
        let branchName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.mergeBlockedByLocalChanges
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")

            guard let headOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for merge"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOidCopy = headOid.pointee
            try git2Check(
                git_commit_lookup(&headCommit, repo, &headOidCopy),
                context: "Lookup HEAD commit"
            )

            var sourceRef: OpaquePointer?
            defer { if let sourceRef { git_reference_free(sourceRef) } }
            var lookupCode = git_branch_lookup(&sourceRef, repo, branchName, GIT_BRANCH_LOCAL)
            if lookupCode == GIT_ENOTFOUND.rawValue {
                lookupCode = git_branch_lookup(&sourceRef, repo, branchName, GIT_BRANCH_REMOTE)
            }
            if lookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.branchNotFound(branchName)
            }
            try git2Check(lookupCode, context: "Lookup merge branch \(branchName)")

            guard let sourceOid = git_reference_target(sourceRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve source branch target for merge"))
            }

            var sourceCommit: OpaquePointer?
            defer { if let sourceCommit { git_commit_free(sourceCommit) } }
            var sourceOidCopy = sourceOid.pointee
            try git2Check(
                git_commit_lookup(&sourceCommit, repo, &sourceOidCopy),
                context: "Lookup source branch commit"
            )

            var annotatedSource: OpaquePointer?
            defer { if let annotatedSource { git_annotated_commit_free(annotatedSource) } }
            try git2Check(
                git_annotated_commit_from_ref(&annotatedSource, repo, sourceRef),
                context: "Create annotated source commit"
            )

            var analysis = git_merge_analysis_t(rawValue: 0)
            var preference = git_merge_preference_t(rawValue: 0)

            var theirHeads: [OpaquePointer?] = [annotatedSource]
            try theirHeads.withUnsafeMutableBufferPointer { buffer in
                try git2Check(
                    git_merge_analysis(&analysis, &preference, repo, buffer.baseAddress, 1),
                    context: "Analyze merge"
                )
            }

            if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
                return MergeResult(
                    kind: .upToDate,
                    sourceBranch: branchName,
                    newCommitSHA: oidToHex(headOid)
                )
            }

            if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
                // Use the same guarded checkout as a pull, never a hard reset.
                var options = git_checkout_options()
                git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
                if try Self.hasUncommittedChanges(repo: repo) { throw LocalGitError.mergeBlockedByLocalChanges }
                guard let refName = git_reference_name(headRef).map({ String(cString: $0) }) else { throw LocalGitError.mergeBlockedByLocalChanges }
                var transaction: OpaquePointer?
                defer { if let transaction { git_transaction_free(transaction) } }
                try git2Check(git_transaction_new(&transaction, repo), context: "Protect merge branch")
                try git2Check(git_transaction_lock_ref(transaction, "HEAD"), context: "Lock merge HEAD")
                if refName != "HEAD" { try git2Check(git_transaction_lock_ref(transaction, refName), context: "Lock merge branch") }
                var current = git_oid()
                try git2Check(git_reference_name_to_id(&current, repo, "HEAD"), context: "Recheck merge HEAD")
                guard git_oid_equal(&current, headOid) != 0 else { throw LocalGitError.mergeBlockedByLocalChanges }
                try git2Check(git_checkout_tree(repo, sourceCommit, &options), context: "Safely receive merged files")
                var tree: OpaquePointer?; var index: OpaquePointer?
                defer { if let tree { git_tree_free(tree) }; if let index { git_index_free(index) } }
                try git2Check(git_commit_tree(&tree, sourceCommit), context: "Read merged tree")
                try git2Check(git_repository_index(&index, repo), context: "Open merged index")
                try git2Check(git_index_read_tree(index, tree), context: "Record merged files")
                try git2Check(git_index_write(index), context: "Save merged index")
                try git2Check(git_transaction_set_target(transaction, refName, sourceOid, nil, "merge: fast-forward"), context: "Advance merged branch")
                try git2Check(git_transaction_commit(transaction), context: "Save merged branch")
                try Self.recordReceivedFiles(repo: repo, before: headOid, after: sourceOid)
                return MergeResult(kind: .fastForwarded, sourceBranch: branchName, newCommitSHA: oidToHex(sourceOid))
            }
            guard analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 else {
                throw LocalGitError.libgit2("The histories cannot be combined safely.")
            }

            // Keep both parents reachable even if another operation later aborts.
            var protectedRef: OpaquePointer?
            defer { if let protectedRef { git_reference_free(protectedRef) } }
            let recoveryName = "refs/vaultbridge/recovery/merge-" + UUID().uuidString
            try git2Check(git_reference_create(&protectedRef, repo, recoveryName, headOid, 0, "Before combine"), context: "Protect local history")
            var remoteRecovery: OpaquePointer?
            defer { if let remoteRecovery { git_reference_free(remoteRecovery) } }
            try git2Check(git_reference_create(&remoteRecovery, repo, recoveryName + "-incoming", sourceOid, 0, "Incoming history"), context: "Protect incoming history")

            // libgit2 applies non-conflicting entries AND persists merge state.
            // The previous in-memory index shortcut returned on conflicts before
            // checkout, making incoming notes look deleted on the next save.
            var mergeOptions = git_merge_options()
            git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
            mergeOptions.flags = UInt32(GIT_MERGE_FIND_RENAMES.rawValue)
            var checkout = git_checkout_options()
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
            if try Self.hasUncommittedChanges(repo: repo) { throw LocalGitError.mergeBlockedByLocalChanges }
            try theirHeads.withUnsafeMutableBufferPointer { buffer in
                try git2Check(git_merge(repo, buffer.baseAddress, 1, &mergeOptions, &checkout), context: "Safely combine files")
            }
            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read merged index")
            if git_index_has_conflicts(index) != 0 { throw LocalGitError.mergeConflictsDetected }

            var treeOid = git_oid()
            try git2Check(git_index_write_tree(&treeOid, index), context: "Write merge tree")
            try git2Check(git_index_write(index), context: "Write merge index")

            var tree: OpaquePointer?
            defer { if let tree { git_tree_free(tree) } }
            try git2Check(git_tree_lookup(&tree, repo, &treeOid), context: "Lookup merge tree")

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            let commitMessage = "Merge branch '\(branchName)'"
            var mergeCommitOid = git_oid()
            var parents: [OpaquePointer?] = [headCommit, sourceCommit]
            try parents.withUnsafeMutableBufferPointer { buffer in
                try git2Check(
                    git_commit_create(
                        &mergeCommitOid,
                        repo,
                        "HEAD",
                        signature,
                        signature,
                        nil,
                        commitMessage,
                        tree,
                        2,
                        buffer.baseAddress
                    ),
                    context: "Create merge commit"
                )
            }

            try Self.recordReceivedFiles(repo: repo, before: headOid, after: &mergeCommitOid)
            try git2Check(git_repository_state_cleanup(repo), context: "Cleanup merge state")

            return MergeResult(
                kind: .mergeCommitted,
                sourceBranch: branchName,
                newCommitSHA: oidToHex(&mergeCommitOid)
            )
        }.value
    }

    func revertCommit(oid: String, message: String, authorName: String, authorEmail: String) async throws -> RevertResult {
        let repoPath = self.localURL.path
        let targetOIDString = oid.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            if try Self.hasUncommittedChanges(repo: repo) {
                throw LocalGitError.revertBlockedByLocalChanges
            }

            var revertOID = git_oid()
            try targetOIDString.withCString { cOID in
                try git2Check(git_oid_fromstr(&revertOID, cOID), context: "Parse revert OID")
            }

            var revertCommit: OpaquePointer?
            defer { if let revertCommit { git_commit_free(revertCommit) } }
            var revertOIDCopy = revertOID
            try git2Check(git_commit_lookup(&revertCommit, repo, &revertOIDCopy), context: "Lookup revert target")

            var revertOpts = git_revert_options()
            git_revert_options_init(&revertOpts, UInt32(GIT_REVERT_OPTIONS_VERSION))
            revertOpts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            let revertCode = git_revert(repo, revertCommit, &revertOpts)
            if revertCode != 0 && revertCode != GIT_EMERGECONFLICT.rawValue {
                try git2Check(revertCode, context: "Apply revert")
            }

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read revert index")

            if git_index_has_conflicts(index) == 1 {
                return RevertResult(kind: .conflicts, targetOID: targetOIDString, newCommitSHA: nil)
            }

            var treeOID = git_oid()
            try git2Check(git_index_write_tree(&treeOID, index), context: "Write revert tree")
            try git2Check(git_index_write(index), context: "Write revert index")

            var tree: OpaquePointer?
            defer { if let tree { git_tree_free(tree) } }
            try git2Check(git_tree_lookup(&tree, repo, &treeOID), context: "Lookup revert tree")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD for revert commit")

            guard let headOID = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD during revert commit"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOIDCopy = headOID.pointee
            try git2Check(git_commit_lookup(&headCommit, repo, &headOIDCopy), context: "Lookup HEAD commit for revert")

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            let fallbackSummary = git_commit_message(revertCommit)
                .map { String(cString: $0).components(separatedBy: .newlines).first ?? "" }
                ?? ""
            let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Revert \"\(fallbackSummary)\""
                : message

            var commitOID = git_oid()
            var parents: [OpaquePointer?] = [headCommit]
            try parents.withUnsafeMutableBufferPointer { buffer in
                try git2Check(
                    git_commit_create(
                        &commitOID,
                        repo,
                        "HEAD",
                        signature,
                        signature,
                        nil,
                        commitMessage,
                        tree,
                        1,
                        buffer.baseAddress
                    ),
                    context: "Create revert commit"
                )
            }

            if git_repository_state(repo) != Int32(GIT_REPOSITORY_STATE_NONE.rawValue) {
                try git2Check(git_repository_state_cleanup(repo), context: "Cleanup revert state")
            }

            return RevertResult(kind: .reverted, targetOID: targetOIDString, newCommitSHA: oidToHex(&commitOID))
        }.value
    }

    func completeMerge(message: String, authorName: String, authorEmail: String) async throws -> MergeFinalizeResult {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue) else {
                throw LocalGitError.noMergeInProgress
            }

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read merge index")

            if git_index_has_conflicts(index) == 1 {
                throw LocalGitError.mergeConflictsDetected
            }

            let pendingWrites = try Self.statusEntries(repo: repo).filter {
                $0.workTreeStatus != nil && $0.workTreeStatus != .untracked
            }
            guard pendingWrites.isEmpty else {
                throw LocalGitError.repositoryCorrupted("Some files changed while combining versions. Your saved versions are protected. Review the changed files before finishing; nothing has been uploaded.")
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")

            guard let headOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD during merge finalize"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOidCopy = headOid.pointee
            try git2Check(git_commit_lookup(&headCommit, repo, &headOidCopy), context: "Lookup HEAD commit")

            var mergeHeadOid = try Self.readMergeHeadOID(repo: repo)
            var mergeHeadCommit: OpaquePointer?
            defer { if let mergeHeadCommit { git_commit_free(mergeHeadCommit) } }
            try git2Check(git_commit_lookup(&mergeHeadCommit, repo, &mergeHeadOid), context: "Lookup MERGE_HEAD commit")

            var treeOid = git_oid()
            try git2Check(git_index_write_tree(&treeOid, index), context: "Write merge tree")
            try git2Check(git_index_write(index), context: "Write merge index")

            var tree: OpaquePointer?
            defer { if let tree { git_tree_free(tree) } }
            try git2Check(git_tree_lookup(&tree, repo, &treeOid), context: "Lookup merge tree")

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Merge commit"
                : message

            var commitOid = git_oid()
            var parents: [OpaquePointer?] = [headCommit, mergeHeadCommit]
            try parents.withUnsafeMutableBufferPointer { buffer in
                try git2Check(
                    git_commit_create(
                        &commitOid,
                        repo,
                        "HEAD",
                        signature,
                        signature,
                        nil,
                        commitMessage,
                        tree,
                        2,
                        buffer.baseAddress
                    ),
                    context: "Create merge commit"
                )
            }

            try Self.recordReceivedFiles(repo: repo, before: headOid, after: &commitOid)
            try git2Check(git_repository_state_cleanup(repo), context: "Cleanup merge state")

            return MergeFinalizeResult(newCommitSHA: oidToHex(&commitOid))
        }.value
    }

    func abortMerge() async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue) else {
                throw LocalGitError.noMergeInProgress
            }

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")

            guard let headOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD during merge abort"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOidCopy = headOid.pointee
            try git2Check(git_commit_lookup(&headCommit, repo, &headOidCopy), context: "Lookup HEAD commit")

            try git2Check(git_reset(repo, headCommit, GIT_RESET_HARD, nil), context: "Reset working tree on merge abort")
            try git2Check(git_repository_state_cleanup(repo), context: "Cleanup merge state")
        }.value
    }

    func continueRebase(pat: String, authorName: String, authorEmail: String) async throws -> LocalPullResult {
        let repoPath = self.localURL.path
        let localURL = self.localURL

        let rebaseResult = try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            guard Self.isRebaseState(git_repository_state(repo)) else {
                throw LocalGitError.noRebaseInProgress
            }

            var oldHeadRef: OpaquePointer?
            defer { if let oldHeadRef { git_reference_free(oldHeadRef) } }
            try git2Check(git_repository_head(&oldHeadRef, repo), context: "Read HEAD before continuing rebase")
            guard let oldHeadOid = git_reference_target(oldHeadRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD before continuing rebase"))
            }
            var oldHeadOidCopy = oldHeadOid.pointee

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read rebase index")
            if git_index_has_conflicts(index) == 1 {
                throw LocalGitError.rebaseConflictsDetected
            }

            var rebaseOpts = git_rebase_options()
            git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))
            rebaseOpts.merge_options.flags = UInt32(GIT_MERGE_FIND_RENAMES.rawValue)
            rebaseOpts.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            var rebase: OpaquePointer?
            defer { if let rebase { git_rebase_free(rebase) } }
            try git2Check(git_rebase_open(&rebase, repo, &rebaseOpts), context: "Open rebase")

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            var commitOid = git_oid()
            let commitCode = git_rebase_commit(&commitOid, rebase, nil, signature, nil, nil)
            if commitCode == GIT_EUNMERGED.rawValue || commitCode == GIT_EMERGECONFLICT.rawValue {
                throw LocalGitError.rebaseConflictsDetected
            }
            if commitCode != GIT_EAPPLIED.rawValue {
                try git2Check(commitCode, context: "Commit resolved rebase change")
            }

            try Self.advanceRebase(repo: repo, rebase: rebase, signature: signature)

            var newHeadRef: OpaquePointer?
            defer { if let newHeadRef { git_reference_free(newHeadRef) } }
            try git2Check(git_repository_head(&newHeadRef, repo), context: "Read HEAD after continuing rebase")
            guard let newHeadOid = git_reference_target(newHeadRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD after continuing rebase"))
            }

            let changedPaths = try Self.changedPathsBetween(repo: repo, oldOID: &oldHeadOidCopy, newOID: newHeadOid)
            return (result: LocalPullResult(updated: true, newCommitSHA: oidToHex(newHeadOid)), changedPaths: changedPaths)
        }.value

        if rebaseResult.result.updated {
            let lfsResult = try await Self.hydrateLFSIfNeeded(
                localURL: localURL,
                pat: pat,
                candidatePaths: rebaseResult.changedPaths
            )
            if lfsResult.checkedOutCount > 0 {
                DebugLogger.shared.info("lfs", "Hydrated Git LFS files after continuing rebase", detail: "\(lfsResult.checkedOutCount) files")
            }
        }

        return rebaseResult.result
    }

    func abortRebase() async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            guard Self.isRebaseState(git_repository_state(repo)) else {
                throw LocalGitError.noRebaseInProgress
            }

            var rebaseOpts = git_rebase_options()
            git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))

            var rebase: OpaquePointer?
            defer { if let rebase { git_rebase_free(rebase) } }
            try git2Check(git_rebase_open(&rebase, repo, &rebaseOpts), context: "Open rebase")
            try git2Check(git_rebase_abort(rebase), context: "Abort rebase")
        }.value
    }

    func conflictSession() async throws -> ConflictSession {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            let stateCode = git_repository_state(repo)
            let kind = Self.conflictSessionKind(from: UInt32(stateCode))

            // Conflicts are index entries (that is also where status derives
            // GIT_STATUS_CONFLICTED from), so enumerate them directly instead
            // of running a full worktree status walk with recursive untracked
            // scanning. Measured on a 2.5k-file vault this turns a ~40 ms
            // scan — paid before every automatic commit — into microseconds,
            // and it scales with conflict count instead of vault size.
            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Open index for conflicts")

            var unmerged: [String] = []
            if git_index_has_conflicts(index) != 0 {
                var iterator: OpaquePointer?
                defer { if let iterator { git_index_conflict_iterator_free(iterator) } }
                try git2Check(
                    git_index_conflict_iterator_new(&iterator, index),
                    context: "Iterate index conflicts"
                )
                var seen = Set<String>()
                while true {
                    var ancestor: UnsafePointer<git_index_entry>?
                    var ours: UnsafePointer<git_index_entry>?
                    var theirs: UnsafePointer<git_index_entry>?
                    let nextCode = git_index_conflict_next(
                        &ancestor, &ours, &theirs, iterator
                    )
                    if nextCode == GIT_ITEROVER.rawValue { break }
                    try git2Check(nextCode, context: "Iterate index conflicts")

                    guard let pathPtr = (ours ?? theirs ?? ancestor)?.pointee.path else { continue }
                    // Same NFC normalisation the status pipeline applies.
                    let path = String(cString: pathPtr).precomposedStringWithCanonicalMapping
                    if seen.insert(path).inserted {
                        unmerged.append(path)
                    }
                }
                unmerged.sort()
            }

            if kind == .none && unmerged.isEmpty {
                return .none
            }

            return ConflictSession(kind: kind, unmergedPaths: unmerged)
        }.value
    }

    func resolveConflict(path: String, strategy: ConflictResolutionStrategy) async throws {
        let repoPath = self.localURL.path
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        try await Task.detached {
            guard !trimmedPath.isEmpty else {
                throw LocalGitError.conflictPathNotFound(path)
            }

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read index")

            let conflictPath = strdup(trimmedPath)!
            defer { free(conflictPath) }

            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let conflictLookupCode = git_index_conflict_get(&ancestor, &ours, &theirs, index, conflictPath)
            if conflictLookupCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.conflictPathNotFound(trimmedPath)
            }
            try git2Check(conflictLookupCode, context: "Lookup conflict entry for \(trimmedPath)")

            try Self.backupWorkingFile(trimmedPath, repo: repo)
            if strategy != .manual && (strategy == .ours ? ours : theirs) == nil {
                let file = try Self.guardedFile(trimmedPath, repo: repo)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try git2Check(git_index_conflict_remove(index, conflictPath), context: "Record chosen deletion")
                let remove = git_index_remove_bypath(index, conflictPath)
                if remove != GIT_ENOTFOUND.rawValue { try git2Check(remove, context: "Stage chosen deletion") }
                try git2Check(git_index_write(index), context: "Save conflict choice")
                return
            }

            if strategy != .manual {
                let storage = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
                defer { storage.deallocate() }

                var checkoutOptions = git_checkout_options()
                git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))

                let resolutionFlag = strategy == .ours
                    ? GIT_CHECKOUT_USE_OURS.rawValue
                    : GIT_CHECKOUT_USE_THEIRS.rawValue
                checkoutOptions.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | resolutionFlag

                makeStrarray(conflictPath, into: &checkoutOptions.paths, storage: storage)

                try git2Check(
                    git_checkout_index(repo, index, &checkoutOptions),
                    context: "Apply \(strategy.rawValue) resolution for \(trimmedPath)"
                )
            }

            try trimmedPath.withCString { cPath in
                let removeConflictCode = git_index_conflict_remove(index, cPath)
                if removeConflictCode != GIT_ENOTFOUND.rawValue {
                    try git2Check(removeConflictCode, context: "Remove conflict state for \(trimmedPath)")
                }

                try git2Check(git_index_add_bypath(index, cPath), context: "Stage resolved file \(trimmedPath)")
            }

            try git2Check(git_index_write(index), context: "Write index")
        }.value
    }

    func conflictDetail(path: String) async throws -> ConflictFileDetail {
        let repoPath = self.localURL.path
        let lookupPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await Task.detached {
            guard !lookupPath.isEmpty else {
                throw LocalGitError.conflictPathNotFound(path)
            }

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read index")

            var iterator: OpaquePointer?
            defer { if let iterator { git_index_conflict_iterator_free(iterator) } }
            try git2Check(
                git_index_conflict_iterator_new(&iterator, index),
                context: "Create conflict iterator"
            )

            // Walk every conflict triple in the index. A rename/rename can have
            // ancestor/ours/theirs at three different paths, so we accept a match
            // on any side. The `lookupPath` argument is whatever the UI displayed
            // — usually one of those paths.
            while true {
                var ancestorEntry: UnsafePointer<git_index_entry>?
                var oursEntry: UnsafePointer<git_index_entry>?
                var theirsEntry: UnsafePointer<git_index_entry>?
                let nextCode = git_index_conflict_next(
                    &ancestorEntry, &oursEntry, &theirsEntry, iterator
                )
                if nextCode == GIT_ITEROVER.rawValue { break }
                try git2Check(nextCode, context: "Iterate conflicts")

                let ancestorPath = ancestorEntry.flatMap { String(cString: $0.pointee.path) }
                let oursPath = oursEntry.flatMap { String(cString: $0.pointee.path) }
                let theirsPath = theirsEntry.flatMap { String(cString: $0.pointee.path) }

                let matches = [ancestorPath, oursPath, theirsPath].contains(lookupPath)
                guard matches else { continue }

                let ancestor = try Self.readConflictSide(repo: repo, entry: ancestorEntry)
                let ours = try Self.readConflictSide(repo: repo, entry: oursEntry)
                let theirs = try Self.readConflictSide(repo: repo, entry: theirsEntry)

                return ConflictFileDetail(
                    lookupPath: lookupPath,
                    ancestor: ancestor,
                    ours: ours,
                    theirs: theirs,
                    workingCopyFingerprint: try Self.workingFingerprint(lookupPath, repo: repo)
                )
            }

            throw LocalGitError.conflictPathNotFound(lookupPath)
        }.value
    }

    func resolveConflictWithContent(
        path: String,
        content: Data,
        additionalPathsToRemove: [String]
    ) async throws {
        let repoPath = self.localURL.path
        let workdir = self.localURL.path
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let extras = additionalPathsToRemove
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != trimmedPath }

        try await Task.detached {
            guard !trimmedPath.isEmpty else {
                throw LocalGitError.conflictPathNotFound(path)
            }

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read index")

            _ = try Self.guardedFile(trimmedPath, repo: repo)
            if trimmedPath.lowercased().hasSuffix(".json") {
                _ = try JSONSerialization.jsonObject(with: content, options: [.fragmentsAllowed])
            }
            for name in [trimmedPath] + extras { try Self.backupWorkingFile(name, repo: repo) }

            // Write the resolved bytes to the working tree, creating any missing
            // parent directories. The kept path may not exist on disk yet (e.g.
            // after `git_merge` left only conflict markers, or if the user is
            // picking a new filename for a rename/rename).
            let absoluteKeepPath = (workdir as NSString).appendingPathComponent(trimmedPath)
            let parent = (absoluteKeepPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
            try content.write(to: URL(fileURLWithPath: absoluteKeepPath), options: .atomic)

            // Clear conflict markers for every path involved in this conflict.
            // libgit2 keys conflicts by path, so a rename/rename has multiple
            // entries to clear (ancestor path + both rename targets).
            for clearPath in [trimmedPath] + extras {
                try clearPath.withCString { cPath in
                    let removeCode = git_index_conflict_remove(index, cPath)
                    if removeCode != 0 && removeCode != GIT_ENOTFOUND.rawValue {
                        try git2Check(removeCode, context: "Remove conflict for \(clearPath)")
                    }
                }
            }

            // Drop unwanted paths from the index and the working tree. For a
            // rename/rename where the user keeps only one filename, this deletes
            // the alternative on disk too so the resulting commit is clean.
            for extra in extras {
                try extra.withCString { cPath in
                    let removeCode = git_index_remove_bypath(index, cPath)
                    if removeCode != 0 && removeCode != GIT_ENOTFOUND.rawValue {
                        try git2Check(removeCode, context: "Remove index entry for \(extra)")
                    }
                }
                let absoluteExtra = (workdir as NSString).appendingPathComponent(extra)
                if FileManager.default.fileExists(atPath: absoluteExtra) {
                    try? FileManager.default.removeItem(atPath: absoluteExtra)
                }
            }

            // Stage the resolved file last so it is the canonical entry.
            try trimmedPath.withCString { cPath in
                try git2Check(
                    git_index_add_bypath(index, cPath),
                    context: "Stage resolved file \(trimmedPath)"
                )
            }

            try git2Check(git_index_write(index), context: "Write index")
        }.value
    }

    func commitLocal(
        message: String,
        authorName: String,
        authorEmail: String
    ) async throws -> String {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            guard try Self.hasStagedChanges(repo: repo, index: index) else {
                throw LocalGitError.noChanges
            }

            try git2Check(git_index_write(index), context: "Write index")

            var treeOid = git_oid()
            try git2Check(git_index_write_tree(&treeOid, index), context: "Write tree from index")

            var tree: OpaquePointer?
            defer { if let tree { git_tree_free(tree) } }
            try git2Check(git_tree_lookup(&tree, repo, &treeOid), context: "Lookup tree")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            var parentCommit: OpaquePointer?
            defer { if let parentCommit { git_commit_free(parentCommit) } }

            let headCode = git_repository_head(&headRef, repo)
            if headCode == 0 {
                guard let headOid = git_reference_target(headRef) else {
                    throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for commit"))
                }
                var headOidCopy = headOid.pointee
                try git2Check(
                    git_commit_lookup(&parentCommit, repo, &headOidCopy),
                    context: "Lookup HEAD commit"
                )
            } else if headCode != GIT_EUNBORNBRANCH.rawValue && headCode != GIT_ENOTFOUND.rawValue {
                try git2Check(headCode, context: "Read HEAD")
            }

            var sig: UnsafeMutablePointer<git_signature>?
            defer { if let sig { git_signature_free(sig) } }
            try createGitSignature(&sig, authorName: authorName, authorEmail: authorEmail)

            var commitOid = git_oid()
            if let parentCommit {
                var parents: [OpaquePointer?] = [parentCommit]
                try parents.withUnsafeMutableBufferPointer { buf in
                    try git2Check(
                        git_commit_create(
                            &commitOid, repo, "HEAD",
                            sig, sig,
                            nil,
                            message,
                            tree,
                            1,
                            buf.baseAddress
                        ),
                        context: "Create commit"
                    )
                }
            } else {
                try git2Check(
                    git_commit_create(
                        &commitOid, repo, "HEAD",
                        sig, sig,
                        nil,
                        message,
                        tree,
                        0,
                        nil
                    ),
                    context: "Create initial commit"
                )
            }

            return oidToHex(&commitOid)
        }.value
    }

    /// Read one stage of an index conflict into a `ConflictFileSide`. Caps
    /// content at `conflictBlobByteCap` so a runaway binary doesn't blow up
    /// memory; oversized blobs come back with `content == nil`.
    private static func readConflictSide(
        repo: OpaquePointer?,
        entry: UnsafePointer<git_index_entry>?
    ) throws -> ConflictFileSide? {
        guard let entry else { return nil }

        let entryPath = String(cString: entry.pointee.path)
        var oidCopy = entry.pointee.id
        let oidString = oidToHex(&oidCopy)

        var blob: OpaquePointer?
        defer { if let blob { git_blob_free(blob) } }
        try git2Check(
            git_blob_lookup(&blob, repo, &oidCopy),
            context: "Lookup conflict blob for \(entryPath)"
        )

        let isBinary = git_blob_is_binary(blob) == 1
        let rawSize = git_blob_rawsize(blob)
        let size = Int(clamping: rawSize)

        var content: Data? = nil
        if size <= conflictBlobByteCap, let raw = git_blob_rawcontent(blob), size > 0 {
            content = Data(bytes: raw, count: size)
        } else if size == 0 {
            content = Data()
        }

        return ConflictFileSide(
            path: entryPath,
            oid: oidString,
            isBinary: isBinary,
            content: content
        )
    }

    private static let conflictBlobByteCap = 2 * 1024 * 1024

    // MARK: - Diff

    func unifiedDiff(path: String?) async throws -> UnifiedDiffResult {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var options = git_diff_options()
            git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
            options.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
                | UInt32(GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue)
                | UInt32(GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue)

            // Do NOT use a pathspec here. libgit2 pathspec matching is
            // byte-exact, so an NFC pathspec never matches an NFD filename
            // on APFS (and vice-versa). Instead we compute the full diff
            // and filter the results in Swift using NFC-normalised comparison,
            // which correctly handles Korean/CJK filenames on all Apple
            // filesystems. The full diff is cheap for typical vault sizes.

            let headTree = try Self.headTreeForDiff(repo: repo)
            defer { if let headTree { git_tree_free(headTree) } }

            var diff: OpaquePointer?
            try git2Check(
                git_diff_tree_to_workdir_with_index(&diff, repo, headTree, &options),
                context: "Create HEAD-to-workdir diff"
            )
            guard let diff else { return .empty }
            defer { git_diff_free(diff) }

            var findOptions = git_diff_find_options()
            git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
            _ = git_diff_find_similar(diff, &findOptions)

            let collector = DiffPrintCollector()
            let collectorPtr = Unmanaged.passRetained(collector).toOpaque()
            defer { Unmanaged<DiffPrintCollector>.fromOpaque(collectorPtr).release() }

            try git2Check(
                git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, diffPrintCallback, collectorPtr),
                context: "Render unified diff"
            )

            let rawPatch = collector.output
            let patchChunks = Self.splitPatchByFile(rawPatch)

            let deltaCount = Int(git_diff_num_deltas(diff))
            var files: [GitFileDiff] = []
            files.reserveCapacity(deltaCount)

            // NFC-normalise the requested path once for Unicode-safe comparison.
            // This lets a single-file diff request find files regardless of
            // whether the git objects use NFC and the filesystem uses NFD (or
            // vice-versa), which is the common case for Korean/CJK filenames
            // on Apple platforms.
            let requestedNFC = path?.precomposedStringWithCanonicalMapping

            for i in 0..<deltaCount {
                guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }

                let oldPath = delta.old_file.path.map { String(cString: $0) }
                let newPath = delta.new_file.path.map { String(cString: $0) }
                let filePath = newPath ?? oldPath ?? "<unknown>"
                let patch = i < patchChunks.count ? patchChunks[i] : ""

                // When a specific path was requested, skip files that don't
                // match — using NFC-normalised comparison so that NFC/NFD
                // variants of the same filename are treated as equal.
                if let requested = requestedNFC {
                    let fileNFC = filePath.precomposedStringWithCanonicalMapping
                    let oldNFC  = oldPath?.precomposedStringWithCanonicalMapping ?? ""
                    guard fileNFC == requested || oldNFC == requested else { continue }
                }

                files.append(
                    GitFileDiff(
                        path: filePath,
                        oldPath: oldPath,
                        newPath: newPath,
                        changeType: Self.diffChangeType(from: delta.status),
                        isBinary: patch.contains("Binary files"),
                        patch: patch
                    )
                )
            }

            return UnifiedDiffResult(files: files, rawPatch: rawPatch)
        }.value
    }

    /// Stage all worktree changes (adds/modifies/deletes) like `git add -A`.
    ///
    /// We combine `git_index_add_all` (captures new/untracked + modified files)
    /// and `git_index_update_all` (captures tracked-file deletions) so callback
    /// pushes can atomically include rename/create/delete operations without
    /// relying on rename detection timing.
    func lfsAutoTrackingCandidates(paths: [String]? = nil) async throws -> [GitLFSAutoTrackingCandidate] {
        let repositoryURL = self.localURL
        return try await Task.detached {
            try GitLFSService.autoTrackingCandidates(repositoryURL: repositoryURL, candidatePaths: paths)
        }.value
    }

    func stageAll() async throws {
        try await stageAll(lfsAutoTrack: false)
    }

    func stageAll(lfsAutoTrack: Bool) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            try Self.guardSuspiciousChanges(repo: repo)

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            try Self.addAllAndUpdateAllIgnoringEviction(repo: repo, index: index)

            try GitLFSService.cleanAndStageLFSFiles(
                repo: repo,
                index: index,
                autoTrackingPolicy: lfsAutoTrack ? .default : .disabled
            )

            try git2Check(git_index_write(index), context: "Write index")
        }.value
    }

    /// `git add -A` through libgit2's own passes, minus iCloud eviction noise:
    /// placeholders are never added and evicted originals are never removed.
    private static func addAllAndUpdateAllIgnoringEviction(repo: OpaquePointer?, index: OpaquePointer?) throws {
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let context = EvictionCallbackContext(workdirURL: URL(fileURLWithPath: workdir, isDirectory: true))
        let payload = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<EvictionCallbackContext>.fromOpaque(payload).release() }

        // Both passes can remove a missing tracked file (add_all mirrors
        // `git add -A`), so both get the same eviction filter.
        try git2Check(
            git_index_add_all(index, nil, UInt32(GIT_INDEX_ADD_DEFAULT.rawValue), skipICloudEvictionCallback, payload),
            context: "Stage all added/modified files"
        )
        try git2Check(
            git_index_update_all(index, nil, skipICloudEvictionCallback, payload),
            context: "Stage tracked deletions/modifications"
        )
    }

    func rebuildIndexFromWorkingTree(lfsAutoTrack: Bool) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")
            Self.setPrecomposeUnicode(repo: repo)

            try Self.guardSuspiciousChanges(repo: repo)

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")
            if git_index_has_conflicts(index) == 1 {
                throw LocalGitError.conflictSessionInProgress(.none)
            }

            // Start from the last commit so entries that only ever existed
            // in the index (a staged file that was later deleted, an entry
            // written by another tool) are discarded instead of preserved.
            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            let headCode = git_repository_head(&headRef, repo)
            if headCode == 0, let headOid = git_reference_target(headRef) {
                var headOidCopy = headOid.pointee
                var headCommit: OpaquePointer?
                defer { if let headCommit { git_commit_free(headCommit) } }
                try git2Check(git_commit_lookup(&headCommit, repo, &headOidCopy), context: "Lookup HEAD commit")
                var headTree: OpaquePointer?
                defer { if let headTree { git_tree_free(headTree) } }
                try git2Check(git_commit_tree(&headTree, headCommit), context: "Get HEAD tree")
                try git2Check(git_index_read_tree(index, headTree), context: "Reset index to HEAD")
            } else if headCode == GIT_EUNBORNBRANCH.rawValue || headCode == GIT_ENOTFOUND.rawValue {
                try git2Check(git_index_clear(index), context: "Clear index")
            } else {
                try git2Check(headCode, context: "Read HEAD")
            }

            // update_all walks the index entries against the disk (deletions
            // and edits of tracked files, by raw path bytes); add_all walks
            // the disk for untracked files, honoring .gitignore. Evicted
            // iCloud files stay as committed.
            try Self.addAllAndUpdateAllIgnoringEviction(repo: repo, index: index)

            try GitLFSService.cleanAndStageLFSFiles(
                repo: repo,
                index: index,
                autoTrackingPolicy: lfsAutoTrack ? .default : .disabled
            )

            try git2Check(git_index_write(index), context: "Write rebuilt index")
        }.value
    }

    func stageChanges(_ entries: [GitStatusEntry], lfsAutoTrack: Bool) async throws {
        guard !entries.isEmpty else { return }
        let repoPath = self.localURL.path

        try await Task.detached {
            let started = ContinuousClock.now
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            try Self.guardSuspiciousChanges(repo: repo)

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            let workdirURL = git_repository_workdir(repo).map {
                URL(fileURLWithPath: String(cString: $0), isDirectory: true)
            }
            for entry in entries {
                if ICloudEviction.isPlaceholder(path: entry.path) { continue }
                try entry.stagingPath.withCString { cPath in
                    let addCode = git_index_add_bypath(index, cPath)
                    if addCode == GIT_ENOTFOUND.rawValue {
                        // An evicted iCloud file is not a deletion; keep the
                        // committed copy untouched.
                        if let workdirURL, ICloudEviction.isEvicted(path: entry.path, in: workdirURL) {
                            return
                        }
                        try Self.removeIndexEntry(path: entry.path, index: index)
                    } else {
                        try git2Check(addCode, context: "Stage changed path")
                        // Any other entry for the same file (a different
                        // Unicode form, or a duplicate) must not survive as a
                        // permanent "deleted" twin.
                        for raw in Self.rawIndexPaths(matching: entry.path, index: index) where !Self.sameBytes(raw, entry.stagingPath) {
                            _ = raw.withCString { git_index_remove_bypath(index, $0) }
                        }
                    }
                }

                if let oldPath = entry.oldPath, oldPath != entry.path {
                    try Self.removeIndexEntry(path: oldPath, index: index)
                }
            }

            try GitLFSService.cleanAndStageLFSFiles(
                repo: repo,
                index: index,
                // `path` is NFC-normalized for display.  AutoNoteMover and
                // other iOS file providers can leave the actual directory
                // entry in another Unicode byte form, recorded in
                // `stagingPath`.  Cleaning the display spelling misses that
                // file, leaves a regular blob/deleted twin in the index, and
                // every subsequent save reports the move again.
                candidatePaths: Array(Set(entries.flatMap { [$0.path, $0.stagingPath] })),
                autoTrackingPolicy: lfsAutoTrack ? .default : .disabled
            )
            try git2Check(git_index_write(index), context: "Write index")
            let elapsed = started.duration(to: .now)
            DebugLogger.shared.info("performance", "Checkpoint paths staged", detail: "count=\(entries.count), duration=\(elapsed)")
        }.value
    }

    func stage(path: String) async throws {
        try await stage(path: path, oldPath: nil, lfsAutoTrack: false)
    }

    func unstage(path: String) async throws {
        try await unstage(path: path, oldPath: nil)
    }

    func stage(path: String, oldPath: String?) async throws {
        try await stage(path: path, oldPath: oldPath, lfsAutoTrack: false)
    }

    func stage(path: String, oldPath: String?, lfsAutoTrack: Bool) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            // Try to add the file first. If it no longer exists on disk
            // (deletion, rename, or move), `git_index_add_bypath` returns
            // GIT_ENOTFOUND — fall back to `git_index_remove_bypath` so the
            // removal is recorded in the index. This also closes the TOCTOU
            // window of checking file existence before calling add_bypath.
            try path.withCString { cPath in
                let addCode = git_index_add_bypath(index, cPath)
                if addCode == GIT_ENOTFOUND.rawValue {
                    // Missing on disk: record the deletion, resolving the index
                    // entry by canonical path if the bytes differ.
                    try Self.removeIndexEntry(path: path, index: index)
                } else {
                    try git2Check(addCode, context: "Stage \(path)")
                    for raw in Self.rawIndexPaths(matching: path, index: index) where !Self.sameBytes(raw, path) {
                        _ = raw.withCString { git_index_remove_bypath(index, $0) }
                    }
                }
            }

            // For a rename, also drop the old path from the index. Without
            // this, the commit keeps the HEAD blob at the old path alongside
            // the newly-added blob at the new path.
            if let oldPath, oldPath != path {
                try Self.removeIndexEntry(path: oldPath, index: index)
            }

            try GitLFSService.cleanAndStageLFSFiles(
                repo: repo,
                index: index,
                candidatePaths: [path],
                autoTrackingPolicy: lfsAutoTrack ? .default : .disabled
            )

            try git2Check(git_index_write(index), context: "Write index")
        }.value
    }

    func unstage(path: String, oldPath: String?) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }

            var targetObject: OpaquePointer?
            defer { if let targetObject { git_object_free(targetObject) } }

            let headCode = git_repository_head(&headRef, repo)
            if headCode == 0 {
                guard let oid = git_reference_target(headRef) else {
                    throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD while unstaging"))
                }
                try git2Check(
                    git_object_lookup(&targetObject, repo, oid, GIT_OBJECT_ANY),
                    context: "Lookup HEAD object"
                )
            } else if headCode != GIT_EUNBORNBRANCH.rawValue && headCode != GIT_ENOTFOUND.rawValue {
                try git2Check(headCode, context: "Read HEAD for unstage")
            }

            // For a renamed entry, also reset the old path so HEAD's blob is
            // restored at its original name — otherwise unstaging leaves the
            // old path missing from the index.
            var paths: [String] = [path]
            if let oldPath, oldPath != path {
                paths.append(oldPath)
            }

            let cStrings = paths.map { strdup($0)! }
            let storage = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count)
            defer {
                for cString in cStrings { free(cString) }
                storage.deallocate()
            }
            for (index, cString) in cStrings.enumerated() {
                storage.advanced(by: index).pointee = cString
            }

            var pathspec = git_strarray()
            pathspec.strings = storage
            pathspec.count = cStrings.count

            try git2Check(
                git_reset_default(repo, targetObject, &pathspec),
                context: "Unstage \(path)"
            )
        }.value
    }

    func discardChanges(path: String) async throws {
        let repoPath = self.localURL.path
        let fullPath = self.localURL.appendingPathComponent(path).path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            // Check whether the file is tracked (has an index entry or exists
            // in HEAD). The status path is NFC-normalized; the index entry may
            // hold another Unicode form, so resolve the raw bytes first.
            let path = Self.rawIndexPaths(matching: path, index: index).first ?? path
            let existsInIndex = path.withCString { cPath in
                git_index_get_bypath(index, cPath, 0) != nil
            }

            // Also check if file exists in HEAD tree (covers staged-new files)
            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            let hasHead = git_repository_head(&headRef, repo) == 0

            var existsInHead = false
            if hasHead, let oid = git_reference_target(headRef) {
                var commit: OpaquePointer?
                defer { if let commit { git_commit_free(commit) } }
                var oidCopy = oid.pointee
                if git_commit_lookup(&commit, repo, &oidCopy) == 0 {
                    var tree: OpaquePointer?
                    defer { if let tree { git_tree_free(tree) } }
                    if git_commit_tree(&tree, commit) == 0 {
                        var entry: OpaquePointer?
                        existsInHead = path.withCString { cPath in
                            git_tree_entry_bypath(&entry, tree, cPath) == 0
                        }
                        if let entry { git_tree_entry_free(entry) }
                    }
                }
            }

            if !existsInIndex && !existsInHead {
                // Purely untracked file — remove from disk
                try FileManager.default.removeItem(atPath: fullPath)
                return
            }

            let cString = strdup(path)!
            let storage = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
            defer {
                free(cString)
                storage.deallocate()
            }

            var pathspec = git_strarray()
            makeStrarray(cString, into: &pathspec, storage: storage)

            // Unstage: reset index entry to HEAD so staged changes are cleared
            if hasHead {
                var headObject: OpaquePointer?
                defer { if let headObject { git_object_free(headObject) } }
                if let headOID = git_reference_target(headRef) {
                    try git2Check(
                        git_object_lookup(&headObject, repo, headOID, GIT_OBJECT_ANY),
                        context: "Lookup HEAD for reset"
                    )
                }
                try git2Check(
                    git_reset_default(repo, headObject, &pathspec),
                    context: "Unstage \(path)"
                )
            } else {
                // No HEAD (unborn branch) — remove from index directly
                try git2Check(
                    git_index_remove_bypath(index, cString),
                    context: "Remove from index \(path)"
                )
                try git2Check(git_index_write(index), context: "Write index")
            }

            // Restore working tree to HEAD
            if existsInHead {
                var opts = git_checkout_options()
                git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                opts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)
                opts.paths = pathspec

                try git2Check(
                    git_checkout_head(repo, &opts),
                    context: "Discard changes in \(path)"
                )
            } else {
                // File doesn't exist in HEAD (was newly added) — remove from disk
                try? FileManager.default.removeItem(atPath: fullPath)
            }
        }.value
    }

    func discardAllChanges() async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            let headCode = git_repository_head(&headRef, repo)

            // Unborn branch (no HEAD yet): nothing to revert to. Clear the
            // index and remove any remaining untracked files.
            if headCode == GIT_EUNBORNBRANCH.rawValue || headCode == GIT_ENOTFOUND.rawValue {
                var index: OpaquePointer?
                defer { if let index { git_index_free(index) } }
                try git2Check(git_repository_index(&index, repo), context: "Get index")
                try git2Check(git_index_clear(index), context: "Clear index")
                try git2Check(git_index_write(index), context: "Write index")
                return
            }
            try git2Check(headCode, context: "Read HEAD for discard all")

            guard let headOid = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for discard all"))
            }

            var headCommit: OpaquePointer?
            defer { if let headCommit { git_commit_free(headCommit) } }
            var headOidCopy = headOid.pointee
            try git2Check(
                git_commit_lookup(&headCommit, repo, &headOidCopy),
                context: "Lookup HEAD commit for discard all"
            )

            var opts = git_checkout_options()
            git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            opts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue) |
                                     UInt32(GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue)

            // HARD reset resets the index to HEAD's tree in addition to
            // overwriting the working tree. `git_checkout_head` alone leaves
            // stale index state behind when both the index and the worktree
            // are dirty, so the file-level revert path already works around
            // this by unstaging explicitly before the checkout.
            try git2Check(
                git_reset(repo, headCommit, GIT_RESET_HARD, &opts),
                context: "Hard reset to HEAD"
            )
        }.value
    }

    func createRecoveryReference() async throws -> GitRecoverySnapshot {
        let repoPath = self.localURL.path
        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD for recovery")
            guard let target = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted("Could not resolve HEAD for recovery.")
            }
            var oid = target.pointee
            let sha = oidToHex(&oid)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var name = "refs/vaultbridge/recovery/\(formatter.string(from: Date()))-\(sha.prefix(12))"
            var recoveryRef: OpaquePointer?
            defer { if let recoveryRef { git_reference_free(recoveryRef) } }
            var code = name.withCString {
                git_reference_create(&recoveryRef, repo, $0, &oid, 0, "vaultbridge: protected recovery snapshot")
            }
            if code == GIT_EEXISTS.rawValue {
                name += "-\(UUID().uuidString.prefix(8).lowercased())"
                code = name.withCString {
                    git_reference_create(&recoveryRef, repo, $0, &oid, 0, "vaultbridge: protected recovery snapshot")
                }
            }
            try git2Check(code, context: "Create protected recovery reference")
            return GitRecoverySnapshot(referenceName: name, commitSHA: sha)
        }.value
    }

    func hardReset(referenceName: String) async throws -> String {
        let repoPath = self.localURL.path
        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var remoteRef: OpaquePointer?
            defer { if let remoteRef { git_reference_free(remoteRef) } }
            try referenceName.withCString {
                try git2Check(git_reference_lookup(&remoteRef, repo, $0), context: "Find server branch")
            }
            guard let target = git_reference_target(remoteRef) else {
                throw LocalGitError.repositoryCorrupted("The server branch has no target commit.")
            }
            var oid = target.pointee
            var commit: OpaquePointer?
            defer { if let commit { git_commit_free(commit) } }
            try git2Check(git_commit_lookup(&commit, repo, &oid), context: "Read server commit")

            var options = git_checkout_options()
            git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            options.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue) | UInt32(GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue)
            try git2Check(git_reset(repo, commit, GIT_RESET_HARD, &options), context: "Replace phone copy with server copy")
            return oidToHex(&oid)
        }.value
    }

    // MARK: - Stash

    func listStashes() async throws -> [GitStashEntry] {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            let collector = StashListCollector()
            let collectorPtr = Unmanaged.passRetained(collector).toOpaque()
            defer { Unmanaged<StashListCollector>.fromOpaque(collectorPtr).release() }

            try git2Check(
                git_stash_foreach(repo, stashForeachCallback, collectorPtr),
                context: "List stashes"
            )

            return collector.entries
        }.value
    }

    func saveStash(message: String, authorName: String, authorEmail: String, includeUntracked: Bool) async throws -> GitStashEntry {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var signature: UnsafeMutablePointer<git_signature>?
            defer { if let signature { git_signature_free(signature) } }
            try createGitSignature(&signature, authorName: authorName, authorEmail: authorEmail)

            var stashOID = git_oid()
            let flags: UInt32 = includeUntracked
                ? UInt32(GIT_STASH_INCLUDE_UNTRACKED.rawValue)
                : UInt32(GIT_STASH_DEFAULT.rawValue)
            let stashCode = git_stash_save(&stashOID, repo, signature, message, flags)
            if stashCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.stashNothingToSave
            }
            try git2Check(stashCode, context: "Save stash")

            let entries = try await self.listStashes()
            let stashOIDHex = oidToHex(&stashOID)
            if let match = entries.first(where: { $0.oid == stashOIDHex }) {
                return match
            }

            return GitStashEntry(index: 0, oid: stashOIDHex, message: message)
        }.value
    }

    func applyStash(index: Int, reinstateIndex: Bool) async throws -> StashApplyResult {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var options = git_stash_apply_options()
            git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
            options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            if reinstateIndex {
                options.flags = UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue)
            }

            let applyCode = git_stash_apply(repo, index, &options)
            if applyCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.stashNotFound(index)
            }
            if applyCode == GIT_EMERGECONFLICT.rawValue {
                return StashApplyResult(kind: .conflicts, index: index)
            }
            try git2Check(applyCode, context: "Apply stash")

            return StashApplyResult(kind: .applied, index: index)
        }.value
    }

    func popStash(index: Int, reinstateIndex: Bool) async throws -> StashApplyResult {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var options = git_stash_apply_options()
            git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
            options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            if reinstateIndex {
                options.flags = UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue)
            }

            let popCode = git_stash_pop(repo, index, &options)
            if popCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.stashNotFound(index)
            }
            if popCode == GIT_EMERGECONFLICT.rawValue {
                return StashApplyResult(kind: .conflicts, index: index)
            }
            try git2Check(popCode, context: "Pop stash")

            return StashApplyResult(kind: .applied, index: index)
        }.value
    }

    func dropStash(index: Int) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            let dropCode = git_stash_drop(repo, index)
            if dropCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.stashNotFound(index)
            }
            try git2Check(dropCode, context: "Drop stash")
        }.value
    }

    // MARK: - Tags

    func listTags() async throws -> [GitTag] {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var tagNames = git_strarray()
            defer { git_strarray_free(&tagNames) }
            try git2Check(git_tag_list(&tagNames, repo), context: "List tags")

            var tags: [GitTag] = []
            for i in 0..<tagNames.count {
                guard let rawName = tagNames.strings[i] else { continue }
                let shortName = String(cString: rawName)
                let refName = "refs/tags/\(shortName)"

                // Resolve the tag reference
                var ref: OpaquePointer?
                defer { if let ref { git_reference_free(ref) } }
                guard git_reference_lookup(&ref, repo, refName) == 0,
                      let refOIDPtr = git_reference_target(ref) else { continue }

                let refOID = oidToHex(refOIDPtr)

                // Peel to the underlying commit for targetOID
                var peeledObj: OpaquePointer?
                defer { if let peeledObj { git_object_free(peeledObj) } }
                guard git_reference_peel(&peeledObj, ref, GIT_OBJECT_COMMIT) == 0 else { continue }
                let targetOID = oidToHex(git_object_id(peeledObj))

                // Determine if the ref points to a tag object (annotated) or a commit (lightweight)
                var pointedObj: OpaquePointer?
                defer { if let pointedObj { git_object_free(pointedObj) } }
                var mutableOID = refOIDPtr.pointee
                if git_object_lookup(&pointedObj, repo, &mutableOID, GIT_OBJECT_ANY) == 0,
                   git_object_type(pointedObj) == GIT_OBJECT_TAG {
                    // Annotated tag — extract message
                    var tagObj: OpaquePointer?
                    defer { if let tagObj { git_tag_free(tagObj) } }
                    let message: String?
                    if git_tag_lookup(&tagObj, repo, &mutableOID) == 0, let tagObj {
                        message = git_tag_message(tagObj).map { String(cString: $0) }
                            .map { $0.trimmingCharacters(in: .newlines) }
                    } else {
                        message = nil
                    }
                    tags.append(GitTag(name: refName, oid: refOID, kind: .annotated, message: message, targetOID: targetOID))
                } else {
                    // Lightweight tag
                    tags.append(GitTag(name: refName, oid: refOID, kind: .lightweight, message: nil, targetOID: targetOID))
                }
            }
            return tags.sorted { $0.shortName.localizedCaseInsensitiveCompare($1.shortName) == .orderedAscending }
        }.value
    }

    func createTag(name: String, targetOID: String?, message: String?, authorName: String, authorEmail: String) async throws -> GitTag {
        let repoPath = self.localURL.path

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            // Resolve target: HEAD if no targetOID provided
            var targetObj: OpaquePointer?
            defer { if let targetObj { git_object_free(targetObj) } }

            if let targetOID, !targetOID.isEmpty {
                var oid = git_oid()
                try git2Check(git_oid_fromstr(&oid, targetOID), context: "Parse target OID")
                try git2Check(git_object_lookup(&targetObj, repo, &oid, GIT_OBJECT_COMMIT), context: "Lookup target commit")
            } else {
                try git2Check(git_revparse_single(&targetObj, repo, "HEAD"), context: "Resolve HEAD for tag")
            }

            var tagOid = git_oid()
            let refName = "refs/tags/\(name)"

            if let msg = message, !msg.isEmpty {
                // Annotated tag
                var sig: UnsafeMutablePointer<git_signature>?
                defer { if let sig { git_signature_free(sig) } }
                try createGitSignature(&sig, authorName: authorName, authorEmail: authorEmail)

                let createCode = git_tag_create(&tagOid, repo, name, targetObj, sig, msg, 0)
                if createCode == GIT_EEXISTS.rawValue {
                    throw LocalGitError.tagAlreadyExists(name)
                }
                try git2Check(createCode, context: "Create annotated tag")

                let targetOIDHex = oidToHex(git_object_id(targetObj))
                return GitTag(name: refName, oid: oidToHex(&tagOid), kind: .annotated, message: msg, targetOID: targetOIDHex)
            } else {
                // Lightweight tag
                let createCode = git_tag_create_lightweight(&tagOid, repo, name, targetObj, 0)
                if createCode == GIT_EEXISTS.rawValue {
                    throw LocalGitError.tagAlreadyExists(name)
                }
                try git2Check(createCode, context: "Create lightweight tag")

                let targetOIDHex = oidToHex(git_object_id(targetObj))
                return GitTag(name: refName, oid: oidToHex(&tagOid), kind: .lightweight, message: nil, targetOID: targetOIDHex)
            }
        }.value
    }

    func deleteTag(name: String) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            let deleteCode = git_tag_delete(repo, name)
            if deleteCode == GIT_ENOTFOUND.rawValue {
                throw LocalGitError.tagNotFound(name)
            }
            try git2Check(deleteCode, context: "Delete tag")
        }.value
    }

    func pushTag(name: String, pat: String) async throws {
        let repoPath = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            // Resolve the local tag OID up front so we have something to
            // compare the remote ref advertisement against during verification.
            var localTagRef: OpaquePointer?
            defer { if let localTagRef { git_reference_free(localTagRef) } }
            try git2Check(
                git_reference_lookup(&localTagRef, repo, "refs/tags/\(name)"),
                context: "Lookup local tag \(name)"
            )
            guard let localTagOidPtr = git_reference_target(localTagRef) else {
                throw LocalGitError.pushFailed(String(localized: "Could not resolve local tag \(name) for verification."))
            }
            var localTagOid = localTagOidPtr.pointee

            var pushRemote: OpaquePointer?
            defer { if let pushRemote { git_remote_free(pushRemote) } }
            let remoteCode = git_remote_lookup(&pushRemote, repo, "origin")
            if remoteCode != 0 {
                throw LocalGitError.pushFailed(String(localized: "No remote 'origin' configured."))
            }

            var pushOpts = git_push_options()
            git_push_options_init(&pushOpts, UInt32(GIT_PUSH_OPTIONS_VERSION))

            let remoteURL = git_remote_url(pushRemote).map { String(cString: $0) }
            let ctx = PushContext(credentials: GitRemoteCredentials.fromTransportPayload(pat), remoteURL: remoteURL)
            let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
            defer { Unmanaged<PushContext>.fromOpaque(ctxPtr).release() }

            pushOpts.callbacks.credentials = pushCredentialCallback
            pushOpts.callbacks.certificate_check = certificateCheckCallback
            pushOpts.callbacks.push_update_reference = pushUpdateReferenceCallback
            pushOpts.callbacks.payload = ctxPtr

            // refs/tags/<name>:refs/tags/<name>
            let refspec = "refs/tags/\(name):refs/tags/\(name)"
            let refspecCStr = strdup(refspec)!
            defer { free(refspecCStr) }
            let stringsPtr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
            defer { stringsPtr.deallocate() }
            stringsPtr[0] = refspecCStr
            var refspecs = git_strarray(strings: stringsPtr, count: 1)

            try git2TransportCheck(
                git_remote_push(pushRemote, &refspecs, &pushOpts),
                context: "Push tag \(name)",
                fallback: ctx.callbackErrorMessage,
                credentialContext: ctx,
                wrapping: LocalGitError.pushFailed
            )

            if !ctx.rejectedRefs.isEmpty {
                let detail = ctx.rejectedRefs
                    .map { "\($0.refname): \($0.reason)" }
                    .joined(separator: "; ")
                throw LocalGitError.pushFailed(detail)
            }

            // Same silent-success path as commitAndPush: git_remote_push can
            // return 0 with no rejected refs even when nothing landed on the
            // server. Tags don't have a remote-tracking namespace, so we
            // reconnect (fetch direction) and read the live ref advertisement
            // from origin to confirm the tag is actually there. The credential
            // one-shot guard from the push has to be reset before reconnecting,
            // otherwise pushCredentialCallback will refuse to authenticate.
            ctx.resetAttempts()
            git_remote_disconnect(pushRemote)
            try git2TransportCheck(
                git_remote_connect(pushRemote, GIT_DIRECTION_FETCH, &pushOpts.callbacks, nil, nil),
                context: "Reconnect to verify tag \(name)",
                fallback: ctx.callbackErrorMessage,
                credentialContext: ctx,
                wrapping: LocalGitError.pushFailed
            )
            defer { git_remote_disconnect(pushRemote) }

            var remoteHeads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
            var headCount: Int = 0
            try git2Check(
                git_remote_ls(&remoteHeads, &headCount, pushRemote),
                context: "List remote refs to verify tag \(name)"
            )

            let targetName = "refs/tags/\(name)"
            var matched = false
            for i in 0..<headCount {
                guard let headPtr = remoteHeads?[i],
                      let namePtr = headPtr.pointee.name else { continue }
                if String(cString: namePtr) == targetName {
                    var advertisedOid = headPtr.pointee.oid
                    if git_oid_equal(&advertisedOid, &localTagOid) == 0 {
                        let remoteHex = oidToHex(&advertisedOid)
                        let localHex = oidToHex(&localTagOid)
                        throw LocalGitError.pushFailed(
                            "Push reported success but origin has tag \(name) at \(remoteHex.prefix(7)), expected \(localHex.prefix(7))."
                        )
                    }
                    matched = true
                    break
                }
            }
            if !matched {
                throw LocalGitError.pushFailed(
                    "Push reported success but origin does not advertise tag \(name). Check PAT scope and that origin URL points at the right repository."
                )
            }
        }.value
    }

    // MARK: - Commit & Push

    func commitAndPush(
        message: String,
        authorName: String,
        authorEmail: String,
        pat: String
    ) async throws -> LocalPushResult {
        let path = self.localURL.path

        return try await Task.detached {
            // Open repository
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")

            // Use currently staged content only
            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Get index")

            let stagedPaths = try Self.stagedChangePaths(repo: repo, index: index)
            guard !stagedPaths.isEmpty else {
                throw LocalGitError.noChanges
            }

            try GitLFSService.validateNoLargeNonLFSBlobs(repo: repo, index: index, candidatePaths: stagedPaths)

            try await GitLFSService(
                localURL: URL(fileURLWithPath: path, isDirectory: true),
                credentials: GitRemoteCredentials.fromTransportPayload(pat)
            ).verifyPushAllowed(changedPaths: stagedPaths)

            try git2Check(git_index_write(index), context: "Write index")

            // Write the staged index tree
            var treeOid = git_oid()
            try git2Check(git_index_write_tree(&treeOid, index), context: "Write tree from staged index")

            var tree: OpaquePointer?
            defer { if let tree { git_tree_free(tree) } }
            try git2Check(git_tree_lookup(&tree, repo, &treeOid), context: "Lookup tree")

            // Resolve optional HEAD commit (parent for non-initial commit)
            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }

            var parentCommit: OpaquePointer?
            defer { if let parentCommit { git_commit_free(parentCommit) } }

            let headCode = git_repository_head(&headRef, repo)
            if headCode == 0 {
                guard let headOid = git_reference_target(headRef) else {
                    throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for commit"))
                }
                var headOidCopy = headOid.pointee
                try git2Check(
                    git_commit_lookup(&parentCommit, repo, &headOidCopy),
                    context: "Lookup HEAD commit"
                )
            } else if headCode != GIT_EUNBORNBRANCH.rawValue && headCode != GIT_ENOTFOUND.rawValue {
                try git2Check(headCode, context: "Read HEAD")
            }

            // Create author/committer signature
            var sig: UnsafeMutablePointer<git_signature>?
            defer { if let sig { git_signature_free(sig) } }
            try createGitSignature(&sig, authorName: authorName, authorEmail: authorEmail)

            // Create the commit
            var commitOid = git_oid()
            if let parentCommit {
                var parents: [OpaquePointer?] = [parentCommit]
                try parents.withUnsafeMutableBufferPointer { buf in
                    try git2Check(
                        git_commit_create(
                            &commitOid, repo, "HEAD",
                            sig, sig,
                            nil,
                            message,
                            tree,
                            1,
                            buf.baseAddress
                        ),
                        context: "Create commit"
                    )
                }
            } else {
                try git2Check(
                    git_commit_create(
                        &commitOid, repo, "HEAD",
                        sig, sig,
                        nil,
                        message,
                        tree,
                        0,
                        nil
                    ),
                    context: "Create initial commit"
                )
            }

            let commitSHA = oidToHex(&commitOid)

            // Ask the LFS server about every pointer in the current snapshot,
            // not only files changed by this commit. This opportunistically
            // repairs older pointers whose backing object never reached the
            // server and blocks the Git ref update if the local object is gone.
            let lfsPointers = try GitLFSService.pointersInIndex(
                repo: repo,
                index: index,
                candidatePaths: nil
            )
            if !lfsPointers.isEmpty {
                let uploaded = try await GitLFSService(
                    localURL: URL(fileURLWithPath: path, isDirectory: true),
                    credentials: GitRemoteCredentials.fromTransportPayload(pat)
                ).uploadObjects(lfsPointers)
                DebugLogger.shared.info("lfs", "Uploaded Git LFS objects before push", detail: "\(uploaded) uploaded, \(lfsPointers.count) referenced")
            }

            // Push to origin
            var pushRemote: OpaquePointer?
            defer { if let pushRemote { git_remote_free(pushRemote) } }
            let remoteCode = git_remote_lookup(&pushRemote, repo, "origin")
            if remoteCode != 0 {
                throw LocalGitError.pushFailed(String(localized: "No remote 'origin' configured."))
            }

            var pushOpts = git_push_options()
            git_push_options_init(&pushOpts, UInt32(GIT_PUSH_OPTIONS_VERSION))

            let remoteURL = git_remote_url(pushRemote).map { String(cString: $0) }
            let pushCtx = PushContext(credentials: GitRemoteCredentials.fromTransportPayload(pat), remoteURL: remoteURL)
            let pushCtxPtr = Unmanaged.passRetained(pushCtx).toOpaque()
            defer { Unmanaged<PushContext>.fromOpaque(pushCtxPtr).release() }

            pushOpts.callbacks.credentials = pushCredentialCallback
            pushOpts.callbacks.certificate_check = certificateCheckCallback
            pushOpts.callbacks.push_update_reference = pushUpdateReferenceCallback
            pushOpts.callbacks.payload = pushCtxPtr

            // Build push refspec for current branch
            let branchName: String
            if let name = git_reference_shorthand(headRef) {
                branchName = String(cString: name)
            } else {
                branchName = "main"
            }
            let refspec = "refs/heads/\(branchName):refs/heads/\(branchName)"
            let refspecCStr = strdup(refspec)!
            defer { free(refspecCStr) }
            let refStringsPtr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
            defer { refStringsPtr.deallocate() }
            refStringsPtr[0] = refspecCStr
            var refspecs = git_strarray(strings: refStringsPtr, count: 1)

            try git2TransportCheck(
                git_remote_push(pushRemote, &refspecs, &pushOpts),
                context: "Push to origin",
                fallback: pushCtx.callbackErrorMessage,
                credentialContext: pushCtx,
                wrapping: LocalGitError.pushFailed
            )

            // git_remote_push returns 0 when the network upload completes, even
            // if the remote rejected the ref update. Check the per-ref status
            // captured by pushUpdateReferenceCallback and surface it as an error.
            if !pushCtx.rejectedRefs.isEmpty {
                let detail = pushCtx.rejectedRefs
                    .map { "\($0.refname): \($0.reason)" }
                    .joined(separator: "; ")
                throw LocalGitError.pushFailed(detail)
            }

            // git_remote_push can also return 0 with an empty rejectedRefs list
            // when libgit2 decides there was nothing to send (e.g. the local
            // branch didn't actually advance past origin/<branch>, the smart-HTTP
            // exchange returned no ack lines, or the server quietly dropped the
            // update). Re-fetch and verify refs/remotes/origin/<branch> actually
            // points at our new commit; if not, surface the failure so the user
            // sees a real error instead of a fake "Push complete".
            try Self.fetchOrigin(repo: repo, pat: pat)
            let remoteTrackingRefName = "refs/remotes/origin/\(branchName)"
            var verifyRef: OpaquePointer?
            defer { if let verifyRef { git_reference_free(verifyRef) } }
            let verifyCode = git_reference_lookup(&verifyRef, repo, remoteTrackingRefName)
            guard verifyCode == 0, let verifyOidPtr = git_reference_target(verifyRef) else {
                throw LocalGitError.pushFailed(
                    "Push reported success but origin does not advertise refs/heads/\(branchName). Check that origin URL, branch name, and PAT scope are correct."
                )
            }
            if git_oid_equal(verifyOidPtr, &commitOid) == 0 {
                let remoteHex = oidToHex(verifyOidPtr)
                throw LocalGitError.pushFailed(
                    "Push reported success but origin/\(branchName) is at \(remoteHex.prefix(7)), expected \(commitSHA.prefix(7)). The remote silently rejected the update — check branch protection rules, PAT scope, and that origin URL points at the right repository."
                )
            }

            return LocalPushResult(commitSHA: commitSHA)
        }.value
    }

    // MARK: - Push Current Branch (post-merge push without committing)

    func pushCurrentBranch(pat: String) async throws {
        let path = self.localURL.path

        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")

            var headRef: OpaquePointer?
            defer { if let headRef { git_reference_free(headRef) } }
            try git2Check(git_repository_head(&headRef, repo), context: "Read HEAD")

            guard let headOidPtr = git_reference_target(headRef) else {
                throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for push"))
            }
            var headOid = headOidPtr.pointee

            let branchName: String
            if let name = git_reference_shorthand(headRef) {
                branchName = String(cString: name)
            } else {
                branchName = "main"
            }

            let pushedPaths = try Self.pushedChangePaths(repo: repo, headRef: headRef)

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Open index before push")
            try GitLFSService.validateNoLargeNonLFSBlobs(
                repo: repo,
                index: index,
                candidatePaths: pushedPaths.isEmpty ? nil : pushedPaths
            )

            try await GitLFSService(
                localURL: URL(fileURLWithPath: path, isDirectory: true),
                credentials: GitRemoteCredentials.fromTransportPayload(pat)
            ).verifyPushAllowed(changedPaths: pushedPaths, refName: "refs/heads/\(branchName)")

            // Verify the complete current LFS snapshot before every branch
            // push. A server-side hole from an older app build must not remain
            // invisible just because the affected path did not change today.
            let lfsPointers = try GitLFSService.pointersInIndex(
                repo: repo,
                index: index,
                candidatePaths: nil
            )
            if !lfsPointers.isEmpty {
                let uploaded = try await GitLFSService(
                    localURL: URL(fileURLWithPath: path, isDirectory: true),
                    credentials: GitRemoteCredentials.fromTransportPayload(pat)
                ).uploadObjects(lfsPointers)
                DebugLogger.shared.info("lfs", "Uploaded Git LFS objects before branch push", detail: "\(uploaded) uploaded, \(lfsPointers.count) referenced")
            }

            var pushRemote: OpaquePointer?
            defer { if let pushRemote { git_remote_free(pushRemote) } }
            let remoteCode = git_remote_lookup(&pushRemote, repo, "origin")
            if remoteCode != 0 {
                throw LocalGitError.pushFailed(String(localized: "No remote 'origin' configured."))
            }

            var pushOpts = git_push_options()
            git_push_options_init(&pushOpts, UInt32(GIT_PUSH_OPTIONS_VERSION))

            let remoteURL = git_remote_url(pushRemote).map { String(cString: $0) }
            let pushCtx = PushContext(credentials: GitRemoteCredentials.fromTransportPayload(pat), remoteURL: remoteURL)
            let pushCtxPtr = Unmanaged.passRetained(pushCtx).toOpaque()
            defer { Unmanaged<PushContext>.fromOpaque(pushCtxPtr).release() }

            pushOpts.callbacks.credentials = pushCredentialCallback
            pushOpts.callbacks.certificate_check = certificateCheckCallback
            pushOpts.callbacks.push_update_reference = pushUpdateReferenceCallback
            pushOpts.callbacks.payload = pushCtxPtr

            let refspec = "refs/heads/\(branchName):refs/heads/\(branchName)"
            let refspecCStr = strdup(refspec)!
            defer { free(refspecCStr) }
            let refStringsPtr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
            defer { refStringsPtr.deallocate() }
            refStringsPtr[0] = refspecCStr
            var refspecs = git_strarray(strings: refStringsPtr, count: 1)

            try git2TransportCheck(
                git_remote_push(pushRemote, &refspecs, &pushOpts),
                context: "Push to origin",
                fallback: pushCtx.callbackErrorMessage,
                credentialContext: pushCtx,
                wrapping: LocalGitError.pushFailed
            )

            if !pushCtx.rejectedRefs.isEmpty {
                let detail = pushCtx.rejectedRefs
                    .map { "\($0.refname): \($0.reason)" }
                    .joined(separator: "; ")
                throw LocalGitError.pushFailed(detail)
            }

            try Self.fetchOrigin(repo: repo, pat: pat)
            let remoteTrackingRefName = "refs/remotes/origin/\(branchName)"
            var verifyRef: OpaquePointer?
            defer { if let verifyRef { git_reference_free(verifyRef) } }
            let verifyCode = git_reference_lookup(&verifyRef, repo, remoteTrackingRefName)
            guard verifyCode == 0, let verifyOidPtr = git_reference_target(verifyRef) else {
                throw LocalGitError.pushFailed(
                    "Push reported success but origin does not advertise refs/heads/\(branchName). Check that origin URL, branch name, and PAT scope are correct."
                )
            }
            if git_oid_equal(verifyOidPtr, &headOid) == 0 {
                let remoteHex = oidToHex(verifyOidPtr)
                let localHex = oidToHex(&headOid)
                throw LocalGitError.pushFailed(
                    "Push reported success but origin/\(branchName) is at \(remoteHex.prefix(7)), expected \(localHex.prefix(7)). The remote silently rejected the update — check branch protection rules, PAT scope, and that origin URL points at the right repository."
                )
            }
        }.value
    }

    func verifySync(pat: String) async throws -> LocalRepoInfo {
        // Hydration validates object size and digest; commit equality alone does
        // not prove that usable attachments exist in the working folder.
        _ = try await Self.hydrateLFSIfNeeded(localURL: localURL, pat: pat)
        try await fetchRemote(pat: pat)
        let session = try await conflictSession()
        guard !session.isActive else { throw LocalGitError.conflictSessionInProgress(session.kind) }
        return try await repoInfo()
    }

    // MARK: - History

    func commitHistory(limit: Int, skip: Int) async throws -> [GitCommitSummary] {
        let repoPath = self.localURL.path
        let safeLimit = max(0, limit)
        let safeSkip = max(0, skip)

        return try await Task.detached {
            guard safeLimit > 0 else { return [] }

            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var walk: OpaquePointer?
            defer { if let walk { git_revwalk_free(walk) } }
            try git2Check(git_revwalk_new(&walk, repo), context: "Create revwalk")

            let sortMode = UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            git_revwalk_sorting(walk, sortMode)

            let pushHeadCode = git_revwalk_push_head(walk)
            if pushHeadCode == GIT_EUNBORNBRANCH.rawValue || pushHeadCode == GIT_ENOTFOUND.rawValue {
                return []
            }
            try git2Check(pushHeadCode, context: "Push HEAD to revwalk")

            var summaries: [GitCommitSummary] = []
            summaries.reserveCapacity(safeLimit)

            var oid = git_oid()
            var walked = 0

            while summaries.count < safeLimit {
                let nextCode = git_revwalk_next(&oid, walk)
                if nextCode == GIT_ITEROVER.rawValue {
                    break
                }
                try git2Check(nextCode, context: "Read next commit from history")

                if walked < safeSkip {
                    walked += 1
                    continue
                }

                var commit: OpaquePointer?
                defer { if let commit { git_commit_free(commit) } }
                var oidCopy = oid
                try git2Check(git_commit_lookup(&commit, repo, &oidCopy), context: "Lookup history commit")

                let fullMessage = git_commit_message(commit).map { String(cString: $0) } ?? ""
                let summaryMessage = fullMessage.components(separatedBy: .newlines).first ?? fullMessage
                let author = git_commit_author(commit)

                let authorName = author?.pointee.name.map { String(cString: $0) } ?? ""
                let authorEmail = author?.pointee.email.map { String(cString: $0) } ?? ""
                let authoredDate = Self.dateFromSignature(author)
                let oidHex = oidToHex(&oidCopy)

                summaries.append(
                    GitCommitSummary(
                        oid: oidHex,
                        shortOID: String(oidHex.prefix(7)),
                        message: summaryMessage,
                        authorName: authorName,
                        authorEmail: authorEmail,
                        authoredDate: authoredDate
                    )
                )

                walked += 1
            }

            return summaries
        }.value
    }

    func commitDetail(oid: String) async throws -> GitCommitDetail {
        let repoPath = self.localURL.path
        let trimmedOID = oid.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, repoPath), context: "Open repo")

            var targetOID = git_oid()
            try trimmedOID.withCString { cOID in
                try git2Check(git_oid_fromstr(&targetOID, cOID), context: "Parse commit OID")
            }

            var commit: OpaquePointer?
            defer { if let commit { git_commit_free(commit) } }
            try git2Check(git_commit_lookup(&commit, repo, &targetOID), context: "Lookup commit detail")

            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""

            let authorSig = git_commit_author(commit)
            let authorName = authorSig?.pointee.name.map { String(cString: $0) } ?? ""
            let authorEmail = authorSig?.pointee.email.map { String(cString: $0) } ?? ""
            let authoredDate = Self.dateFromSignature(authorSig)

            let committerSig = git_commit_committer(commit)
            let committerName = committerSig?.pointee.name.map { String(cString: $0) } ?? ""
            let committerEmail = committerSig?.pointee.email.map { String(cString: $0) } ?? ""
            let committedDate = Self.dateFromSignature(committerSig)

            let parentCount = Int(git_commit_parentcount(commit))
            let parentOIDs: [String] = (0..<parentCount).compactMap { idx in
                guard let parentOID = git_commit_parent_id(commit, UInt32(idx)) else { return nil }
                return oidToHex(parentOID)
            }

            var commitTree: OpaquePointer?
            defer { if let commitTree { git_tree_free(commitTree) } }
            try git2Check(git_commit_tree(&commitTree, commit), context: "Read commit tree")

            var parentCommit: OpaquePointer?
            defer { if let parentCommit { git_commit_free(parentCommit) } }
            var parentTree: OpaquePointer?
            defer { if let parentTree { git_tree_free(parentTree) } }

            if let firstParentOID = git_commit_parent_id(commit, 0) {
                var parentOIDCopy = firstParentOID.pointee
                try git2Check(git_commit_lookup(&parentCommit, repo, &parentOIDCopy), context: "Lookup parent commit")
                try git2Check(git_commit_tree(&parentTree, parentCommit), context: "Read parent tree")
            }

            var diffOptions = git_diff_options()
            git_diff_options_init(&diffOptions, UInt32(GIT_DIFF_OPTIONS_VERSION))

            var diff: OpaquePointer?
            defer { if let diff { git_diff_free(diff) } }
            try git2Check(
                git_diff_tree_to_tree(&diff, repo, parentTree, commitTree, &diffOptions),
                context: "Build commit detail diff"
            )

            var changedFiles: [GitCommitFileChange] = []
            if let diff {
                let deltaCount = Int(git_diff_num_deltas(diff))
                changedFiles.reserveCapacity(deltaCount)

                for i in 0..<deltaCount {
                    guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
                    let oldPath = delta.old_file.path.map { String(cString: $0) }
                    let newPath = delta.new_file.path.map { String(cString: $0) }
                    let path = newPath ?? oldPath ?? "<unknown>"

                    changedFiles.append(
                        GitCommitFileChange(
                            path: path,
                            oldPath: oldPath,
                            newPath: newPath,
                            changeType: Self.diffChangeType(from: delta.status)
                        )
                    )
                }
            }

            let oidHex = oidToHex(&targetOID)
            return GitCommitDetail(
                oid: oidHex,
                message: message,
                authorName: authorName,
                authorEmail: authorEmail,
                authoredDate: authoredDate,
                committerName: committerName,
                committerEmail: committerEmail,
                committedDate: committedDate,
                parentOIDs: parentOIDs,
                changedFiles: changedFiles
            )
        }.value
    }

    // MARK: - Repository Info & Status

    func repoInfo() async throws -> LocalRepoInfo {
        let path = self.localURL.path

        // Timing covers the whole inspection including the executor hop; the
        // box records only durations and aggregate counts (never paths), so
        // the summary is safe for signposts and the in-app debug log.
        let profile = GitInspectionMetricsBox()
        let inspectionState = GitInspectionProfiler.signposter.beginInterval("inspection")
        let totalStart = DispatchTime.now().uptimeNanoseconds

        do {
            let info = try await Task.detached {
                var repo: OpaquePointer?
                defer { if let repo { git_repository_free(repo) } }
                try GitInspectionProfiler.measure("open", into: &profile.metrics.openSeconds) {
                    try git2Check(git_repository_open(&repo, path), context: "Open repo")
                }

                // Ensure core.precomposeunicode is set for repos cloned before
                // this fix was in place. Measured: libgit2 short-circuits
                // same-value config sets, so this never rewrites .git/config
                // after the first run.
                GitInspectionProfiler.measure("config", into: &profile.metrics.configSeconds) {
                    Self.setPrecomposeUnicode(repo: repo)
                }

                // Read HEAD
                var head: OpaquePointer?
                defer { if let head { git_reference_free(head) } }
                try git2Check(git_repository_head(&head, repo), context: "Read HEAD")

                let branch: String
                if let name = git_reference_shorthand(head) {
                    branch = String(cString: name)
                } else {
                    branch = "main"
                }
                let commitSHA = oidToHex(git_reference_target(head)!)

                // This is the phone's last fetched view of the server. Reading
                // the remote-tracking ref is local and fast; the UI labels its
                // age so it is never mistaken for a live network check.
                var remoteCommitSHA = ""
                var remoteRef: OpaquePointer?
                defer { if let remoteRef { git_reference_free(remoteRef) } }
                let remoteName = "refs/remotes/origin/\(branch)"
                if git_reference_lookup(&remoteRef, repo, remoteName) == 0,
                   let remoteTarget = git_reference_target(remoteRef) {
                    remoteCommitSHA = oidToHex(remoteTarget)
                }

                let entries = try Self.statusEntries(repo: repo, profile: profile)
                let changeCount = entries.count
                let syncState = GitInspectionProfiler.measure("syncState", into: &profile.metrics.syncStateSeconds) {
                    Self.syncState(repo: repo, head: head)
                }

                return LocalRepoInfo(
                    branch: branch,
                    commitSHA: commitSHA,
                    changeCount: changeCount,
                    syncState: syncState,
                    statusEntries: entries,
                    remoteCommitSHA: remoteCommitSHA
                )
            }.value

            profile.metrics.totalSeconds = TimeInterval(DispatchTime.now().uptimeNanoseconds - totalStart) / 1_000_000_000
            GitInspectionProfiler.signposter.endInterval("inspection", inspectionState)
            await GitInspectionProfiler.record(profile.metrics)
            return info
        } catch {
            GitInspectionProfiler.signposter.endInterval("inspection", inspectionState)
            throw error
        }
    }

    /// Repairs missing server-side LFS payloads without touching Git history.
    /// The batch API returns upload actions only for objects Forgejo lacks, so
    /// this remains cheap once the repository is healthy.
    func backfillLFSObjects(pat: String) async throws -> GitLFSBackfillResult {
        let path = self.localURL.path
        return try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo for LFS repair")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Open index for LFS repair")

            let pointers = try GitLFSService.pointersInIndex(
                repo: repo,
                index: index,
                candidatePaths: nil
            )
            guard !pointers.isEmpty else { return .empty }

            let uploaded = try await GitLFSService(
                localURL: URL(fileURLWithPath: path, isDirectory: true),
                credentials: GitRemoteCredentials.fromTransportPayload(pat)
            ).uploadObjects(pointers)
            return GitLFSBackfillResult(
                referencedCount: pointers.count,
                uploadedCount: uploaded
            )
        }.value
    }

    // MARK: - Fetch Remote

    func fetchRemote(pat: String) async throws {
        let path = self.localURL.path
        try await Task.detached {
            var repo: OpaquePointer?
            defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, path), context: "Open repo")
            try Self.fetchOrigin(repo: repo, pat: pat)
        }.value
    }

    // MARK: - Helpers

    private static func hydrateLFSIfNeeded(
        localURL: URL,
        pat: String,
        candidatePaths: [String]? = nil
    ) async throws -> GitLFSHydrateResult {
        try await GitLFSService(
            localURL: localURL,
            credentials: GitRemoteCredentials.fromTransportPayload(pat)
        ).hydrateWorktree(candidatePaths: candidatePaths)
    }

    static func classifyPullAction(ahead: Int, behind: Int, hasLocalChanges: Bool) -> PullPlanAction {
        // Any integration (fast-forward or rebase) over a dirty working tree is
        // refused up front. Attempting a rebase with local edits would only die
        // later as a checkout conflict inside git_rebase_init with a confusing
        // libgit2 message — surface the actionable "commit, stash, or discard"
        // outcome instead.
        if behind > 0 && hasLocalChanges {
            return .blockedByLocalChanges
        }
        if ahead > 0 && behind > 0 {
            return .diverged
        }
        if behind > 0 {
            return .fastForward
        }
        // Local ahead-only, unrelated graph, or identical refs.
        return .upToDate
    }

    private static func isRebaseState(_ state: Int32) -> Bool {
        state == Int32(GIT_REPOSITORY_STATE_REBASE.rawValue)
            || state == Int32(GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue)
            || state == Int32(GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue)
    }

    private static func advanceRebase(
        repo: OpaquePointer?,
        rebase: OpaquePointer?,
        signature: UnsafeMutablePointer<git_signature>?
    ) throws {
        while true {
            var operation: UnsafeMutablePointer<git_rebase_operation>?
            let nextCode = git_rebase_next(&operation, rebase)

            if nextCode == GIT_ITEROVER.rawValue {
                try git2Check(git_rebase_finish(rebase, signature), context: "Finish rebase")
                return
            }

            if nextCode == GIT_EMERGECONFLICT.rawValue || nextCode == GIT_EUNMERGED.rawValue {
                throw LocalGitError.rebaseConflictsDetected
            }

            try git2Check(nextCode, context: "Apply next rebase commit")

            var index: OpaquePointer?
            defer { if let index { git_index_free(index) } }
            try git2Check(git_repository_index(&index, repo), context: "Read rebase index")
            if git_index_has_conflicts(index) == 1 {
                throw LocalGitError.rebaseConflictsDetected
            }

            var commitOid = git_oid()
            let commitCode = git_rebase_commit(&commitOid, rebase, nil, signature, nil, nil)
            if commitCode == GIT_EAPPLIED.rawValue {
                continue
            }
            if commitCode == GIT_EUNMERGED.rawValue || commitCode == GIT_EMERGECONFLICT.rawValue {
                throw LocalGitError.rebaseConflictsDetected
            }
            try git2Check(commitCode, context: "Commit rebased change")
        }
    }

    private static func readMergeHeadOID(repo: OpaquePointer?) throws -> git_oid {
        guard let repoPath = git_repository_path(repo) else {
            throw LocalGitError.repositoryCorrupted(String(localized: "Could not read repository path"))
        }

        let mergeHeadURL = URL(fileURLWithPath: String(cString: repoPath)).appendingPathComponent("MERGE_HEAD")
        guard let mergeHeadText = try? String(contentsOf: mergeHeadURL, encoding: .utf8) else {
            throw LocalGitError.repositoryCorrupted(String(localized: "MERGE_HEAD is missing"))
        }

        guard let firstLine = mergeHeadText
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
            throw LocalGitError.repositoryCorrupted(String(localized: "MERGE_HEAD is empty"))
        }

        let oidString = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var mergeHeadOid = git_oid()
        try oidString.withCString { cOID in
            try git2Check(git_oid_fromstr(&mergeHeadOid, cOID), context: "Parse MERGE_HEAD")
        }
        return mergeHeadOid
    }

    private static func dateFromSignature(_ signature: UnsafePointer<git_signature>?) -> Date {
        guard let signature else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(signature.pointee.when.time))
    }

    private static func conflictSessionKind(from state: UInt32) -> ConflictSessionKind {
        switch state {
        case GIT_REPOSITORY_STATE_NONE.rawValue:
            return .none
        case GIT_REPOSITORY_STATE_MERGE.rawValue:
            return .merge
        case GIT_REPOSITORY_STATE_REBASE.rawValue,
             GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue,
             GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue:
            return .rebase
        case GIT_REPOSITORY_STATE_CHERRYPICK.rawValue,
             GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue:
            return .cherryPick
        case GIT_REPOSITORY_STATE_REVERT.rawValue,
             GIT_REPOSITORY_STATE_REVERT_SEQUENCE.rawValue:
            return .revert
        case GIT_REPOSITORY_STATE_APPLY_MAILBOX.rawValue,
             GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE.rawValue:
            return .applyMailbox
        default:
            return .unknown
        }
    }

    private static func splitPatchByFile(_ rawPatch: String) -> [String] {
        guard !rawPatch.isEmpty else { return [] }

        let normalized = rawPatch.hasPrefix("diff --git ")
            ? rawPatch
            : "diff --git \(rawPatch)"

        let parts = normalized.components(separatedBy: "\ndiff --git ")
        return parts.enumerated().compactMap { index, part in
            guard !part.isEmpty else { return nil }
            if index == 0 {
                return part
            }
            return "diff --git \(part)"
        }
    }

    private static func headTreeForDiff(repo: OpaquePointer?) throws -> OpaquePointer? {
        var headRef: OpaquePointer?
        defer { if let headRef { git_reference_free(headRef) } }

        let headCode = git_repository_head(&headRef, repo)
        if headCode == GIT_EUNBORNBRANCH.rawValue || headCode == GIT_ENOTFOUND.rawValue {
            return nil
        }

        try git2Check(headCode, context: "Read HEAD for diff")
        guard let headOid = git_reference_target(headRef) else {
            throw LocalGitError.repositoryCorrupted(String(localized: "Could not resolve HEAD for diff"))
        }

        var headCommit: OpaquePointer?
        defer { if let headCommit { git_commit_free(headCommit) } }

        var headOidCopy = headOid.pointee
        try git2Check(
            git_commit_lookup(&headCommit, repo, &headOidCopy),
            context: "Lookup HEAD commit for diff"
        )

        var headTree: OpaquePointer?
        try git2Check(
            git_commit_tree(&headTree, headCommit),
            context: "Get HEAD tree for diff"
        )

        return headTree
    }

    private static func diffChangeType(from status: git_delta_t) -> GitDiffChangeType {
        switch status {
        case GIT_DELTA_ADDED:
            return .added
        case GIT_DELTA_UNTRACKED:
            return .added
        case GIT_DELTA_MODIFIED:
            return .modified
        case GIT_DELTA_DELETED:
            return .deleted
        case GIT_DELTA_RENAMED:
            return .renamed
        case GIT_DELTA_COPIED:
            return .copied
        case GIT_DELTA_TYPECHANGE:
            return .typeChanged
        case GIT_DELTA_UNREADABLE:
            return .unreadable
        case GIT_DELTA_CONFLICTED:
            return .conflicted
        default:
            return .unknown
        }
    }

    private static func hasStagedChanges(repo: OpaquePointer?, index: OpaquePointer?) throws -> Bool {
        try !stagedChangePaths(repo: repo, index: index).isEmpty
    }

    private static func stagedChangePaths(repo: OpaquePointer?, index: OpaquePointer?) throws -> [String] {
        var headRef: OpaquePointer?
        defer { if let headRef { git_reference_free(headRef) } }

        let headCode = git_repository_head(&headRef, repo)
        if headCode == GIT_EUNBORNBRANCH.rawValue || headCode == GIT_ENOTFOUND.rawValue {
            return indexPaths(index: index)
        }

        try git2Check(headCode, context: "Read HEAD for staged diff")
        guard let headOid = git_reference_target(headRef) else {
            return indexPaths(index: index)
        }

        var headCommit: OpaquePointer?
        defer { if let headCommit { git_commit_free(headCommit) } }
        var headOidCopy = headOid.pointee
        try git2Check(
            git_commit_lookup(&headCommit, repo, &headOidCopy),
            context: "Lookup HEAD commit"
        )

        var headTree: OpaquePointer?
        defer { if let headTree { git_tree_free(headTree) } }
        try git2Check(git_commit_tree(&headTree, headCommit), context: "Get HEAD tree")

        var diff: OpaquePointer?
        defer { if let diff { git_diff_free(diff) } }
        try git2Check(
            git_diff_tree_to_index(&diff, repo, headTree, index, nil),
            context: "Diff HEAD tree to index"
        )

        return diffPaths(diff)
    }

    private static func pushedChangePaths(repo: OpaquePointer?, headRef: OpaquePointer?) throws -> [String] {
        guard let repo, let headRef, let headOid = git_reference_target(headRef) else { return [] }

        var upstreamRef: OpaquePointer?
        let upstreamCode = git_branch_upstream(&upstreamRef, headRef)
        defer { if let upstreamRef { git_reference_free(upstreamRef) } }
        guard upstreamCode == 0, let upstreamOid = git_reference_target(upstreamRef) else { return [] }

        var upstreamCommit: OpaquePointer?
        defer { if let upstreamCommit { git_commit_free(upstreamCommit) } }
        var upstreamOidCopy = upstreamOid.pointee
        try git2Check(git_commit_lookup(&upstreamCommit, repo, &upstreamOidCopy), context: "Lookup upstream commit")

        var headCommit: OpaquePointer?
        defer { if let headCommit { git_commit_free(headCommit) } }
        var headOidCopy = headOid.pointee
        try git2Check(git_commit_lookup(&headCommit, repo, &headOidCopy), context: "Lookup HEAD commit")

        var upstreamTree: OpaquePointer?
        defer { if let upstreamTree { git_tree_free(upstreamTree) } }
        try git2Check(git_commit_tree(&upstreamTree, upstreamCommit), context: "Get upstream tree")

        var headTree: OpaquePointer?
        defer { if let headTree { git_tree_free(headTree) } }
        try git2Check(git_commit_tree(&headTree, headCommit), context: "Get HEAD tree")

        var diff: OpaquePointer?
        defer { if let diff { git_diff_free(diff) } }
        try git2Check(
            git_diff_tree_to_tree(&diff, repo, upstreamTree, headTree, nil),
            context: "Diff upstream tree to HEAD"
        )

        return diffPaths(diff)
    }

    private static func indexPaths(index: OpaquePointer?) -> [String] {
        let count = git_index_entrycount(index)
        var paths: Set<String> = []
        for i in 0..<count {
            guard let entry = git_index_get_byindex(index, i),
                  let path = entry.pointee.path else { continue }
            paths.insert(String(cString: path).precomposedStringWithCanonicalMapping)
        }
        return paths.sorted()
    }

    private static func diffPaths(_ diff: OpaquePointer?) -> [String] {
        guard let diff else { return [] }
        let deltaCount = Int(git_diff_num_deltas(diff))
        var paths: Set<String> = []
        for i in 0..<deltaCount {
            guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
            if let oldPath = delta.old_file.path {
                paths.insert(String(cString: oldPath).precomposedStringWithCanonicalMapping)
            }
            if let newPath = delta.new_file.path {
                paths.insert(String(cString: newPath).precomposedStringWithCanonicalMapping)
            }
        }
        return paths.sorted()
    }

    private static func changedPathsBetween(
        repo: OpaquePointer?,
        oldOID: UnsafePointer<git_oid>?,
        newOID: UnsafePointer<git_oid>?
    ) throws -> [String] {
        guard let repo, let oldOID, let newOID else { return [] }

        var oldOIDCopy = oldOID.pointee
        var newOIDCopy = newOID.pointee

        var oldCommit: OpaquePointer?
        defer { if let oldCommit { git_commit_free(oldCommit) } }
        try git2Check(git_commit_lookup(&oldCommit, repo, &oldOIDCopy), context: "Lookup old commit for changed paths")

        var newCommit: OpaquePointer?
        defer { if let newCommit { git_commit_free(newCommit) } }
        try git2Check(git_commit_lookup(&newCommit, repo, &newOIDCopy), context: "Lookup new commit for changed paths")

        var oldTree: OpaquePointer?
        defer { if let oldTree { git_tree_free(oldTree) } }
        try git2Check(git_commit_tree(&oldTree, oldCommit), context: "Read old tree for changed paths")

        var newTree: OpaquePointer?
        defer { if let newTree { git_tree_free(newTree) } }
        try git2Check(git_commit_tree(&newTree, newCommit), context: "Read new tree for changed paths")

        var diff: OpaquePointer?
        defer { if let diff { git_diff_free(diff) } }
        try git2Check(
            git_diff_tree_to_tree(&diff, repo, oldTree, newTree, nil),
            context: "Diff changed paths"
        )

        return diffPaths(diff)
    }

    private static func fetchOrigin(repo: OpaquePointer?, pat: String) throws {
        var remote: OpaquePointer?
        defer { if let remote { git_remote_free(remote) } }
        try git2Check(git_remote_lookup(&remote, repo, "origin"), context: "Lookup remote")

        var fetchOpts = git_fetch_options()
        git_fetch_options_init(&fetchOpts, UInt32(GIT_FETCH_OPTIONS_VERSION))

        let remoteURL = git_remote_url(remote).map { String(cString: $0) }
        let ctx = CredentialContext(credentials: GitRemoteCredentials.fromTransportPayload(pat), remoteURL: remoteURL)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<CredentialContext>.fromOpaque(ctxPtr).release() }

        fetchOpts.callbacks.credentials = credentialCallback
        fetchOpts.callbacks.certificate_check = certificateCheckCallback
        fetchOpts.callbacks.payload = ctxPtr

        try git2TransportCheck(
            git_remote_fetch(remote, nil, &fetchOpts, nil),
            context: "Fetch",
            fallback: ctx.callbackErrorMessage,
            credentialContext: ctx,
            wrapping: LocalGitError.fetchFailed
        )
    }

    private static func hasUncommittedChanges(repo: OpaquePointer?) throws -> Bool {
        // Reuse statusEntries so that spurious-rename filtering (NFC/NFD on
        // APFS) is applied consistently. A discrepancy between the two code
        // paths caused pulls to be blocked even when the health card showed
        // 0 changed/untracked files.
        return try !statusEntries(repo: repo).isEmpty
    }

    private static func statusEntries(
        repo: OpaquePointer?,
        profile: GitInspectionMetricsBox? = nil
    ) throws -> [GitStatusEntry] {
        var statusOpts = git_status_options()
        git_status_options_init(&statusOpts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        statusOpts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        // Keep status checks fast for large Obsidian vaults. libgit2's rename
        // detection can turn a simple clean/dirty check into an expensive
        // all-files similarity scan; staging already handles renames as
        // delete+add, so status does not need to detect them eagerly.
        statusOpts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            // Refresh unchanged entries' stat cache during the scan and
            // persist it. Measured on a 2.5k-file vault: after an all-files
            // mtime churn the rehash scan costs ~810 ms once and drops back
            // to ~49 ms; without this flag every subsequent scan pays the
            // full ~810 ms again.
            | GIT_STATUS_OPT_UPDATE_INDEX.rawValue

        var statusListSeconds: TimeInterval = 0
        var entryFilterSeconds: TimeInterval = 0
        var lfsCleanSkipped = 0
        var spuriousRenameSkipped = 0
        var evictedSkipped = 0
        var spellingMismatches = 0
        defer {
            if let profile {
                profile.metrics.statusListSeconds += statusListSeconds
                profile.metrics.entryFilterSeconds += entryFilterSeconds
                profile.metrics.lfsCleanSkippedCount += lfsCleanSkipped
                profile.metrics.spuriousRenameSkippedCount += spuriousRenameSkipped
                profile.metrics.evictedSkippedCount += evictedSkipped
            }
        }

        var statusList: OpaquePointer?
        defer { if let statusList { git_status_list_free(statusList) } }

        try GitInspectionProfiler.measure("statusList", into: &statusListSeconds) {
            try git2Check(git_status_list_new(&statusList, repo, &statusOpts), context: "Read status entries")
        }
        guard let statusList else { return [] }

        let filterState = GitInspectionProfiler.signposter.beginInterval("entryFilter")
        let filterStart = DispatchTime.now().uptimeNanoseconds
        defer {
            entryFilterSeconds += TimeInterval(DispatchTime.now().uptimeNanoseconds - filterStart) / 1_000_000_000
            GitInspectionProfiler.signposter.endInterval("entryFilter", filterState)
        }

        let repositoryURL = git_repository_workdir(repo).map {
            URL(fileURLWithPath: String(cString: $0), isDirectory: true)
        }
        var lfsIndex: OpaquePointer?
        defer { if let lfsIndex { git_index_free(lfsIndex) } }
        if git_repository_index(&lfsIndex, repo) != 0 {
            lfsIndex = nil
        }

        let entryCount = Int(git_status_list_entrycount(statusList))
        profile?.metrics.rawStatusEntryCount += entryCount
        var entries: [GitStatusEntry] = []
        entries.reserveCapacity(entryCount)
        // Some iOS File Provider repositories make libgit2 emit an exact-path
        // delete+new pair even though the stage-0 blob and the file are byte
        // identical. Remember those paths so neither half becomes a fake
        // checkpoint.
        var logicallyCleanPaths = Set<String>()
        /// Raw (un-normalized) path per appended entry, for twin merging below.
        var rawPaths: [String] = []

        for index in 0..<entryCount {
            guard let entryPtr = git_status_byindex(statusList, index) else { continue }
            let entry = entryPtr.pointee
            let statusFlags = entry.status.rawValue

            let (path, oldPath): (String, String?) = {
                // For renames, capture both new and old paths so staging can
                // remove the old index entry in the same operation. libgit2
                // reports the rename on either the head_to_index delta
                // (staged rename) or the index_to_workdir delta (unstaged
                // workdir rename).
                if let delta = entry.head_to_index {
                    let deltaStatus = delta.pointee.status
                    let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
                    let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
                    if let newPath {
                        let isRename = deltaStatus == GIT_DELTA_RENAMED
                        return (newPath, (isRename && oldPath != newPath) ? oldPath : nil)
                    }
                    if let oldPath {
                        return (oldPath, nil)
                    }
                }
                if let delta = entry.index_to_workdir {
                    let deltaStatus = delta.pointee.status
                    let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
                    let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
                    if let newPath {
                        let isRename = deltaStatus == GIT_DELTA_RENAMED
                        return (newPath, (isRename && oldPath != newPath) ? oldPath : nil)
                    }
                    if let oldPath {
                        return (oldPath, nil)
                    }
                }
                return ("<unknown>", nil)
            }()

            // Case A — explicit fake rename: libgit2 returned different byte
            // forms (e.g. NFD old, NFC new) that normalise to the same NFC
            // path. Reclassify as untracked so the user can stage the file.
            let isFakeRename: Bool
            if let old = oldPath,
               path.precomposedStringWithCanonicalMapping == old.precomposedStringWithCanonicalMapping,
               path != old {
                isFakeRename = true
            } else {
                isFakeRename = false
            }

            // Case B — spurious rename: core.precomposeunicode normalised
            // BOTH delta paths to the same NFC form, so our closure set
            // oldPath = nil (paths appeared equal). The RENAMED flag is
            // still set even though nothing actually changed. Skip the entry
            // so the file does not appear as "Renamed" after a push where
            // the committed path (NFC) and the on-disk path (NFD) are the
            // same logical file. Only skip if no other meaningful flag
            // (e.g. WT_MODIFIED) remains after clearing the RENAMED bits.
            let hasSpuriousRename = (oldPath == nil) && (
                statusFlags & GIT_STATUS_WT_RENAMED.rawValue != 0 ||
                statusFlags & GIT_STATUS_INDEX_RENAMED.rawValue != 0
            )

            var effectiveFlags = statusFlags
            if isFakeRename {
                // Treat as a new untracked file so staging works.
                effectiveFlags &= ~GIT_STATUS_WT_RENAMED.rawValue
                effectiveFlags &= ~GIT_STATUS_INDEX_RENAMED.rawValue
                effectiveFlags |= GIT_STATUS_WT_NEW.rawValue
            } else if hasSpuriousRename {
                // Clear the artefact RENAMED bits; if nothing meaningful
                // remains the entry will be skipped below.
                effectiveFlags &= ~GIT_STATUS_WT_RENAMED.rawValue
                effectiveFlags &= ~GIT_STATUS_INDEX_RENAMED.rawValue
                if Self.mapIndexStatus(effectiveFlags) == nil &&
                   Self.mapWorkTreeStatus(effectiveFlags) == nil {
                    spuriousRenameSkipped += 1
                    continue   // file is logically clean — omit from results
                }
            }

            if GitLFSService.isCleanHydratedLFSFile(
                repo: repo,
                index: lfsIndex,
                repositoryURL: repositoryURL,
                path: path,
                statusFlags: effectiveFlags
            ) {
                lfsCleanSkipped += 1
                continue
            }

            // iCloud Drive eviction is not a user change: the placeholder
            // is not a new note and the evicted original is not a deletion.
            if let repositoryURL {
                if effectiveFlags & GIT_STATUS_WT_NEW.rawValue != 0,
                   ICloudEviction.isPlaceholder(path: path) {
                    evictedSkipped += 1
                    continue
                }
                if effectiveFlags & GIT_STATUS_WT_DELETED.rawValue != 0,
                   ICloudEviction.isEvicted(path: path, in: repositoryURL) {
                    evictedSkipped += 1
                    continue
                }
            }

            // "Deleted" while the file is on disk means the index holds the
            // name in another Unicode form than the filesystem. That is a
            // rename of the entry, not a deletion of the note. Carry the raw
            // index form as oldPath so staging replaces the entry.
            var normalizationOldPath: String? = nil
            var diskRawPath: String? = nil
            var displayPath: String? = nil
            let normalizedPath = path.precomposedStringWithCanonicalMapping
            if logicallyCleanPaths.contains(normalizedPath) {
                continue
            }
            // Do not use `fileExists(atPath: normalizedPath)` as the presence
            // test.  The local Files provider can be byte-sensitive even when
            // Foundation strings compare canonically, so an NFC lookup can
            // return false while the NFD directory entry is plainly present.
            // Resolve the real spelling one component at a time instead.
            let storedDiskPath = repositoryURL.flatMap {
                workdirStoredForm(of: normalizedPath, in: $0)
            }
            if effectiveFlags & GIT_STATUS_WT_DELETED.rawValue != 0,
               mapIndexStatus(effectiveFlags) == nil,
               let repositoryURL,
               let storedDiskPath {
                let storedNormalizedPath = storedDiskPath.precomposedStringWithCanonicalMapping
                if sameBytes(storedDiskPath, normalizedPath),
                   workdirFileMatchesIndexBlob(
                       repo: repo,
                       index: lfsIndex,
                       repositoryURL: repositoryURL,
                       indexPath: path,
                       diskPath: storedDiskPath
                   ) {
                    logicallyCleanPaths.insert(normalizedPath)
                    DebugLogger.shared.info(
                        "status",
                        "Ignored identical file-provider delete/add pair",
                        detail: GitLFSService.diagnosticSummary(
                            repositoryURL: repositoryURL,
                            index: lfsIndex,
                            path: normalizedPath
                        )
                    )
                    continue
                }
                effectiveFlags &= ~GIT_STATUS_WT_DELETED.rawValue
                effectiveFlags |= GIT_STATUS_WT_RENAMED.rawValue
                let differsBeyondUnicodeNormalization = storedNormalizedPath != normalizedPath
                // The raw bytes of the index entry and of the on-disk name
                // are what staging must reconcile; the reported path is only
                // one view of them.
                normalizationOldPath = differsBeyondUnicodeNormalization
                    ? path
                    : rawIndexPaths(matching: normalizedPath, index: lfsIndex)
                        .first(where: { !sameBytes($0, normalizedPath) })
                // With precomposeunicode enabled, hand libgit2 the NFC form
                // so the index converges instead of preserving the stale NFD
                // spelling. Case-only (or other non-Unicode) differences must
                // instead use the spelling actually present on disk; otherwise
                // a case-insensitive Files provider can alternate one file
                // forever between deleted and untracked.
                diskRawPath = precomposeUnicodeEnabled(repo: repo) && !differsBeyondUnicodeNormalization
                    ? normalizedPath
                    : storedDiskPath
                displayPath = storedNormalizedPath
                spellingMismatches += 1
                DebugLogger.shared.info(
                    "status",
                    "File reported deleted but present on disk",
                    detail: "index=\(unicodeForm(normalizationOldPath ?? path)) disk=\(unicodeForm(diskRawPath ?? path))"
                        + " same-spelling=\(!differsBeyondUnicodeNormalization)"
                        + " precompose=\(precomposeUnicodeEnabled(repo: repo))"
                        + " " + GitLFSService.diagnosticSummary(repositoryURL: repositoryURL, index: lfsIndex, path: normalizedPath)
                )
            } else if effectiveFlags & (GIT_STATUS_WT_NEW.rawValue | GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_TYPECHANGE.rawValue) != 0 {
                diskRawPath = path
            }

            entries.append(
                GitStatusEntry(
                    // Normalise to NFC so paths from git objects (NFC) and
                    // from the APFS/HFS+ filesystem (NFD) compare equal.
                    // Without this, Korean/CJK filenames show as perpetually
                    // modified and never match UI path lookups.
                    path: displayPath ?? normalizedPath,
                    indexStatus: mapIndexStatus(effectiveFlags),
                    workTreeStatus: mapWorkTreeStatus(effectiveFlags),
                    oldPath: normalizationOldPath ?? (isFakeRename ? nil : oldPath?.precomposedStringWithCanonicalMapping),
                    rawPath: diskRawPath.flatMap { sameBytes($0, normalizedPath) ? nil : $0 }
                )
            )
            rawPaths.append(path)
        }

        // Two entries whose paths are canonically equal are one file seen
        // through two Unicode forms: the index holds one, the disk the other.
        // Report it once, as a rename from the raw index form, so staging
        // replaces the old entry instead of leaving a permanent "deleted" twin.
        var merged: [GitStatusEntry] = []
        var mergedRaw: [String] = []
        var positionByPath: [String: Int] = [:]
        for (offset, entry) in entries.enumerated() {
            let raw = rawPaths[offset]
            guard let existing = positionByPath[entry.path] else {
                positionByPath[entry.path] = merged.count
                merged.append(entry)
                mergedRaw.append(raw)
                continue
            }
            let previous = merged[existing]
            let previousRaw = mergedRaw[existing]
            let deletedRaw: String?
            if previous.workTreeStatus == .deleted, entry.workTreeStatus != .deleted {
                deletedRaw = previousRaw
            } else if entry.workTreeStatus == .deleted, previous.workTreeStatus != .deleted {
                deletedRaw = raw
            } else {
                deletedRaw = nil
            }
            if let deletedRaw {
                let diskRaw = sameBytes(deletedRaw, previousRaw) ? raw : previousRaw
                spellingMismatches += 1
                DebugLogger.shared.info(
                    "status",
                    "Spelling mismatch between index and disk (two entries)",
                    detail: "index=\(unicodeForm(deletedRaw)) disk=\(unicodeForm(diskRaw))"
                )
                merged[existing] = GitStatusEntry(
                    path: entry.path,
                    indexStatus: nil,
                    workTreeStatus: .renamed,
                    oldPath: sameBytes(deletedRaw, entry.path) ? nil : deletedRaw,
                    rawPath: sameBytes(diskRaw, entry.path) ? nil : diskRaw
                )
            } else if previous.oldPath != nil || entry.oldPath != nil {
                // One half was a tracked spelling that still exists on disk
                // under the other half's spelling. Prefer the semantic rename
                // over whichever raw entry (often WT_NEW) libgit2 listed first.
                merged[existing] = GitStatusEntry(
                    path: entry.path,
                    indexStatus: previous.indexStatus ?? entry.indexStatus,
                    workTreeStatus: .renamed,
                    oldPath: previous.oldPath ?? entry.oldPath,
                    rawPath: previous.rawPath ?? entry.rawPath
                )
            } else {
                merged[existing] = GitStatusEntry(
                    path: entry.path,
                    indexStatus: previous.indexStatus ?? entry.indexStatus,
                    workTreeStatus: previous.workTreeStatus ?? entry.workTreeStatus,
                    oldPath: previous.oldPath ?? entry.oldPath,
                    rawPath: previous.rawPath ?? entry.rawPath
                )
            }
        }

        if !logicallyCleanPaths.isEmpty {
            merged.removeAll { logicallyCleanPaths.contains($0.path) }
        }
        profile?.metrics.reportedEntryCount += merged.count
        profile?.metrics.spellingMismatchCount += spellingMismatches
        return merged
    }

    private static func mapIndexStatus(_ flags: UInt32) -> GitFileStatusKind? {
        if flags & GIT_STATUS_CONFLICTED.rawValue != 0 { return .conflicted }
        if flags & GIT_STATUS_INDEX_NEW.rawValue != 0 { return .added }
        if flags & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { return .modified }
        if flags & GIT_STATUS_INDEX_DELETED.rawValue != 0 { return .deleted }
        if flags & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { return .renamed }
        if flags & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 { return .typeChanged }
        return nil
    }

    private static func mapWorkTreeStatus(_ flags: UInt32) -> GitFileStatusKind? {
        if flags & GIT_STATUS_CONFLICTED.rawValue != 0 { return .conflicted }
        if flags & GIT_STATUS_WT_NEW.rawValue != 0 { return .untracked }
        if flags & GIT_STATUS_WT_MODIFIED.rawValue != 0 { return .modified }
        if flags & GIT_STATUS_WT_DELETED.rawValue != 0 { return .deleted }
        if flags & GIT_STATUS_WT_RENAMED.rawValue != 0 { return .renamed }
        if flags & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 { return .typeChanged }
        return nil
    }

    private static func syncState(repo: OpaquePointer?, head: OpaquePointer?) -> RepoSyncState {
        guard let head, let localOID = git_reference_target(head) else { return .unknown }

        var upstreamRef: OpaquePointer?
        defer { if let upstreamRef { git_reference_free(upstreamRef) } }

        // Sync uses origin/current-branch even when a newly created branch has
        // no upstream configuration. Compare the same destination everywhere.
        guard let branch = git_reference_shorthand(head).map({ String(cString: $0) }) else { return .unknown }
        let upstreamCode = git_reference_lookup(&upstreamRef, repo, "refs/remotes/origin/\(branch)")
        if upstreamCode != 0 { return .unknown }

        guard let upstreamRef, let upstreamOID = git_reference_target(upstreamRef) else {
            return .unknown
        }

        var ahead: Int = 0
        var behind: Int = 0
        if git_graph_ahead_behind(&ahead, &behind, repo, localOID, upstreamOID) < 0 {
            return .unknown
        }

        if ahead > 0 && behind > 0 { return .diverged }
        if ahead > 0 { return .ahead }
        if behind > 0 { return .behind }
        return .upToDate
    }

    private static func countFiles(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { count += 1 }
        }
        return count
    }
}


// MARK: - Raw index path resolution

extension LocalGitService {
    /// Swift `==` on String is canonical-equivalence, which is exactly the
    /// wrong test when the whole point is that two byte sequences differ.
    fileprivate static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    /// Status entries carry NFC-normalized paths so the UI can match them,
    /// but index entries written by other tools may hold the same name in a
    /// different Unicode form. `git_index_remove_bypath` and friends need the
    /// exact bytes, so resolve them by scanning for canonically equal paths.
    fileprivate static func rawIndexPaths(matching normalizedPath: String, index: OpaquePointer?) -> [String] {
        let wanted = normalizedPath.precomposedStringWithCanonicalMapping
        var matches: [String] = []
        let count = git_index_entrycount(index)
        for i in 0..<count {
            guard let entry = git_index_get_byindex(index, i), let cPath = entry.pointee.path else { continue }
            let raw = String(cString: cPath)
            if raw.precomposedStringWithCanonicalMapping == wanted {
                matches.append(raw)
            }
        }
        return matches
    }

    fileprivate static func precomposeUnicodeEnabled(repo: OpaquePointer?) -> Bool {
        var config: OpaquePointer?
        defer { if let config { git_config_free(config) } }
        guard git_repository_config_snapshot(&config, repo) == 0 else { return false }
        var value: Int32 = 0
        return git_config_get_bool(&value, config, "core.precomposeunicode") == 0 && value != 0
    }

    /// Confirms a suspicious File Provider status pair without trusting stat
    /// metadata. This is only used for paths libgit2 called deleted while
    /// Foundation just enumerated the same spelling on disk.
    static func workdirFileMatchesIndexBlob(
        repo: OpaquePointer?,
        index: OpaquePointer?,
        repositoryURL: URL,
        indexPath: String,
        diskPath: String
    ) -> Bool {
        guard let index,
              let entry = indexPath.withCString({ git_index_get_bypath(index, $0, 0) }) else {
            return false
        }
        var oid = entry.pointee.id
        var blob: OpaquePointer?
        defer { if let blob { git_blob_free(blob) } }
        guard git_blob_lookup(&blob, repo, &oid) == 0, let blob else { return false }
        let rawSize = git_blob_rawsize(blob)
        // Ordinary files above the automatic LFS threshold should never need
        // a large in-memory comparison here. Refuse rather than risk memory
        // pressure if a malformed repository does present one.
        guard rawSize >= 0, rawSize <= 16 * 1024 * 1024 else { return false }
        let size = Int(rawSize)
        guard let disk = try? Data(
            contentsOf: repositoryURL.appendingPathComponent(diskPath),
            options: .mappedIfSafe
        ), disk.count == size else {
            return false
        }
        if size == 0 { return true }
        guard let raw = git_blob_rawcontent(blob) else { return false }
        return disk == Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: raw), count: size, deallocator: .none)
    }

    /// The exact spelling stored on disk, found by matching each component
    /// canonically. This deliberately ignores `core.precomposeunicode` because
    /// callers use it to prove that the file really exists before deciding
    /// which spelling libgit2 should stage.
    static func workdirStoredForm(of normalizedPath: String, in repositoryURL: URL) -> String? {
        let fileManager = FileManager.default
        var current = repositoryURL
        var stored: [String] = []
        for component in normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: current.path) else {
                return nil
            }
            let wanted = component.precomposedStringWithCanonicalMapping
            // Prefer a canonically exact name. Case folding is only a fallback
            // and only when it identifies one unambiguous entry.
            let exact = names.first { $0.precomposedStringWithCanonicalMapping == wanted }
            let folded = names.filter {
                $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard let match = exact ?? (folded.count == 1 ? folded[0] : nil) else { return nil }
            stored.append(match)
            current = current.appendingPathComponent(match)
        }
        return stored.joined(separator: "/")
    }

    /// Coarse, name-free description of a path's Unicode form for the log.
    fileprivate static func unicodeForm(_ path: String) -> String {
        if sameBytes(path, path.precomposedStringWithCanonicalMapping) { return "NFC" }
        if sameBytes(path, path.decomposedStringWithCanonicalMapping) { return "NFD" }
        return "mixed"
    }

    /// Removes an index entry by path, falling back to canonically equal raw
    /// paths when the exact bytes are not found. Returns true if anything was removed.
    /// Removes every index entry for a path, including duplicates and any
    /// canonically-equal spelling. A single `git_index_remove_bypath` removes
    /// one entry; an index that somehow holds the same path twice would keep
    /// producing a phantom "deleted" delta forever.
    @discardableResult
    fileprivate static func removeIndexEntry(path: String, index: OpaquePointer?) throws -> Bool {
        var removed = false
        var candidates = [path]
        candidates.append(contentsOf: rawIndexPaths(matching: path, index: index).filter { !sameBytes($0, path) })
        for candidate in candidates {
            // Loop: one call removes one entry, so drain any duplicates.
            for _ in 0..<8 {
                let code = candidate.withCString { git_index_remove_bypath(index, $0) }
                if code == GIT_ENOTFOUND.rawValue { break }
                if code != 0 {
                    try git2Check(code, context: "Stage deletion")
                    break
                }
                removed = true
            }
        }
        return removed
    }
}

// MARK: - iCloud eviction callbacks for libgit2 whole-tree passes

private final class EvictionCallbackContext {
    let workdirURL: URL
    init(workdirURL: URL) { self.workdirURL = workdirURL }
}

/// Return 1 to skip the path, 0 to include it. Skips iCloud placeholders
/// (never new files) and evicted originals (never deletions).
nonisolated private func skipICloudEvictionCallback(
    path: UnsafePointer<CChar>?,
    matchedPathspec: UnsafePointer<CChar>?,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let path, let payload else { return 0 }
    let relativePath = String(cString: path)
    if ICloudEviction.isPlaceholder(path: relativePath) { return 1 }
    let context = Unmanaged<EvictionCallbackContext>.fromOpaque(payload).takeUnretainedValue()
    return ICloudEviction.isEvicted(path: relativePath, in: context.workdirURL) ? 1 : 0
}

// Recovery manifests are private repository metadata, never diagnostic journals.
extension LocalGitService {
    private struct ReceivedFile: Codable { let path: String; let expected: String; let previous: String? }
    private struct SafetyManifest: Codable { var incoming: [ReceivedFile] = []; var approved: String? }

    private static func safetyURL(repo: OpaquePointer?) throws -> URL {
        guard let directory = git_repository_path(repo) else { throw LocalGitError.notCloned }
        let folder = URL(fileURLWithPath: String(cString: directory)).appendingPathComponent("vaultbridge-safety")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("received.json")
    }
    private static func readSafety(repo: OpaquePointer?) throws -> SafetyManifest {
        let url = try safetyURL(repo: repo)
        guard FileManager.default.fileExists(atPath: url.path) else { return SafetyManifest() }
        return try JSONDecoder().decode(SafetyManifest.self, from: Data(contentsOf: url))
    }
    private static func writeSafety(_ manifest: SafetyManifest, repo: OpaquePointer?) throws {
        try JSONEncoder().encode(manifest).write(to: safetyURL(repo: repo), options: .atomic)
    }
    private static func blobID(repo: OpaquePointer?, commitOID: UnsafePointer<git_oid>, path: String) throws -> String? {
        var commit: OpaquePointer?; defer { if let commit { git_commit_free(commit) } }
        try git2Check(git_commit_lookup(&commit, repo, commitOID), context: "Read saved version")
        var tree: OpaquePointer?; defer { if let tree { git_tree_free(tree) } }
        try git2Check(git_commit_tree(&tree, commit), context: "Read saved files")
        var entry: OpaquePointer?; defer { if let entry { git_tree_entry_free(entry) } }
        let code = git_tree_entry_bypath(&entry, tree, path)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try git2Check(code, context: "Read saved file")
        return oidToHex(git_tree_entry_id(entry))
    }
    private static func recordReceivedFiles(repo: OpaquePointer?, before: UnsafePointer<git_oid>, after: UnsafePointer<git_oid>) throws {
        let paths = try changedPathsBetween(repo: repo, oldOID: before, newOID: after)
        var manifest = try readSafety(repo: repo)
        // A no-op sync must not erase protection of recently received files.
        guard !paths.isEmpty else { return }
        manifest.incoming = try paths.compactMap { path in
            guard let expected = try blobID(repo: repo, commitOID: after, path: path) else { return nil }
            return ReceivedFile(path: path, expected: expected, previous: try blobID(repo: repo, commitOID: before, path: path))
        }
        manifest.approved = nil
        try writeSafety(manifest, repo: repo)
    }
    private static func guardedFile(_ path: String, repo: OpaquePointer?) throws -> URL {
        guard let workdir = git_repository_workdir(repo), !path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0.lowercased() == ".git" }) else {
            throw LocalGitError.repositoryCorrupted("This file path cannot be changed safely.")
        }
        let root = URL(fileURLWithPath: String(cString: workdir)).standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL
        var component = root
        for part in path.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw LocalGitError.repositoryCorrupted("A file uses a symbolic link. Review it before continuing.")
            }
        }
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw LocalGitError.repositoryCorrupted("A file points outside this vault. Review it before continuing.")
        }
        return file
    }
    private static func assessLosses(repo: OpaquePointer?) throws -> SyncSafetyReview? {
        let entries = try statusEntries(repo: repo)
        let deleted = entries.filter { !$0.isConflicted && $0.oldPath == nil && ($0.workTreeStatus == .deleted || $0.indexStatus == .deleted) }
        var index: OpaquePointer?; defer { if let index { git_index_free(index) } }
        try git2Check(git_repository_index(&index, repo), context: "Check saved files")
        let total = max(1, Int(git_index_entrycount(index)))
        var paths = Set<String>()
        if deleted.count >= 20 || (deleted.count >= 5 && Double(deleted.count) / Double(total) >= 0.2) { paths.formUnion(deleted.map(\.path)) }
        let manifest = try readSafety(repo: repo)
        for received in manifest.incoming {
            guard let change = entries.first(where: { $0.path == received.path }), change.oldPath == nil else { continue }
            if change.workTreeStatus == .deleted || change.indexStatus == .deleted { paths.insert(received.path); continue }
            if let previous = received.previous, previous != received.expected {
                let file = try guardedFile(received.path, repo: repo)
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
                   let data = try? Data(contentsOf: file) {
                    var oid = git_oid()
                    try data.withUnsafeBytes { bytes in try git2Check(git_odb_hash(&oid, bytes.baseAddress, data.count, GIT_OBJECT_BLOB), context: "Check file contents") }
                    if oidToHex(&oid) == previous { paths.insert(received.path) }
                }
            }
        }
        guard !paths.isEmpty else { return nil }
        var head = git_oid(); try git2Check(git_reference_name_to_id(&head, repo, "HEAD"), context: "Read recovery version")
        var signature = oidToHex(&head)
        for path in paths.sorted() {
            signature += "\n" + path
            if let data = try? Data(contentsOf: guardedFile(path, repo: repo)) { signature += SHA256.hash(data: data).description }
            else { signature += "missing" }
        }
        let fingerprint = SHA256.hash(data: Data(signature.utf8)).description
        guard manifest.approved != fingerprint else { return nil }
        return SyncSafetyReview(paths: paths.sorted(), fingerprint: fingerprint)
    }
    private static func guardSuspiciousChanges(repo: OpaquePointer?) throws {
        if let review = try assessLosses(repo: repo) { throw LocalGitError.suspiciousChanges(review) }
    }
    func reviewSafetyChanges(approve: Bool, review: SyncSafetyReview) async throws {
        let location = localURL
        try await Task.detached {
            var repo: OpaquePointer?; defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, location.path), context: "Open recovery")
            guard try Self.assessLosses(repo: repo) == review else { throw LocalGitError.repositoryCorrupted("The files changed. Review their latest versions first.") }
            var manifest = try Self.readSafety(repo: repo)
            if approve { manifest.approved = review.fingerprint; try Self.writeSafety(manifest, repo: repo); return }
            var head = git_oid(); try git2Check(git_reference_name_to_id(&head, repo, "HEAD"), context: "Read protected version")
            var restoredIndex: OpaquePointer?
            defer { if let restoredIndex { git_index_free(restoredIndex) } }
            try git2Check(git_repository_index(&restoredIndex, repo), context: "Open restored file index")
            for path in review.paths {
                let file = try Self.guardedFile(path, repo: repo)
                let identifier = try manifest.incoming.first(where: { $0.path == path })?.expected ?? Self.blobID(repo: repo, commitOID: &head, path: path)
                guard let identifier else { continue }
                var oid = git_oid(); try git2Check(git_oid_fromstr(&oid, identifier), context: "Read protected file ID")
                var blob: OpaquePointer?; defer { if let blob { git_blob_free(blob) } }
                try git2Check(git_blob_lookup(&blob, repo, &oid), context: "Read protected file")
                try Self.backupWorkingFile(path, repo: repo)
                let bytes = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
                try git2Check(git_index_add_bypath(restoredIndex, path), context: "Record restored file")
            }
            try git2Check(git_index_write(restoredIndex), context: "Save restored file index")
        }.value
    }
    func restoreFile(path: String, from commit: String) async throws {
        let root = localURL
        try await Task.detached {
            var repo: OpaquePointer?; defer { if let repo { git_repository_free(repo) } }
            try git2Check(git_repository_open(&repo, root.path), context: "Open file recovery")
            guard git_repository_state(repo) == 0 else { throw LocalGitError.repositoryCorrupted("Finish reviewing the current combine before restoring another version.") }
            var oid = git_oid(); try git2Check(git_oid_fromstr(&oid, commit), context: "Read selected checkpoint")
            guard let identifier = try Self.blobID(repo: repo, commitOID: &oid, path: path) else { throw LocalGitError.repositoryCorrupted("This file does not exist in the selected checkpoint.") }
            var blobOID = git_oid(); try git2Check(git_oid_fromstr(&blobOID, identifier), context: "Read saved file ID")
            var blob: OpaquePointer?; defer { if let blob { git_blob_free(blob) } }
            try git2Check(git_blob_lookup(&blob, repo, &blobOID), context: "Read saved file")
            let file = try Self.guardedFile(path, repo: repo)
            try Self.backupWorkingFile(path, repo: repo)
            let bytes = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            var manifest = try Self.readSafety(repo: repo)
            manifest.incoming.removeAll { $0.path == path }
            try Self.writeSafety(manifest, repo: repo)
        }.value
    }

    private static func workingFingerprint(_ path: String, repo: OpaquePointer?) throws -> String {
        let file = try guardedFile(path, repo: repo)
        guard FileManager.default.fileExists(atPath: file.path) else { return "missing" }
        return SHA256.hash(data: try Data(contentsOf: file)).description
    }
    private static func backupWorkingFile(_ path: String, repo: OpaquePointer?) throws {
        let file = try guardedFile(path, repo: repo)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let folder = try safetyURL(repo: repo).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent("content"))
        try Data(path.utf8).write(to: folder.appendingPathComponent("source"), options: .atomic)
    }
}
