#if DEBUG
import Foundation
import libgit2

/// Synthetic on-device test data; never opens a configured user vault.
@MainActor
enum SyncSafetyUIFixture {
    static func prepare(_ state: AppState) async throws {
        _ = git_libgit2_init()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("SyncReview-\(UUID())")
        let root = parent.appendingPathComponent("Practice vault")
        let remote = parent.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        var raw: OpaquePointer?
        guard git_repository_init(&raw, root.path, 0) == 0 else { throw LocalGitError.notCloned }
        git_repository_free(raw); raw = nil
        guard git_repository_init(&raw, remote.path, 1) == 0 else { throw LocalGitError.notCloned }
        git_repository_free(raw)
        let service = LocalGitService(localURL: root)
        try await service.setRemoteURL(name: "origin", url: remote.path)
        let taskTest = ProcessInfo.processInfo.arguments.contains("-SyncTaskConflictUITest")
        let conflictPath = taskTest ? "Tasks.md" : ProcessInfo.processInfo.arguments.contains("-SyncNoteConflictUITest") ? "Note.md" : ".obsidian/app.json"
        let recoveryTest = ProcessInfo.processInfo.arguments.contains("-SyncRecoveryUITest")
        let settings = root.appendingPathComponent(conflictPath)
        try Data((taskTest ? "# Tasks\n- [/] Stretch\n- [/] Walk\n" : "{\"fontSize\":16}\n").utf8).write(to: settings)
        try await service.stageAll()
        _ = try await service.commitLocal(message: "Initial settings", authorName: "Example", authorEmail: "example@example.invalid")
        let branch = try await service.repoInfo().branch
        try await service.createBranch(name: "server")
        try await service.switchBranch(name: "server")
        try Data((taskTest ? "# Tasks\n- [ ] Stretch\n- [x] Walk\n" : "{\"fontSize\":18}\n").utf8).write(to: settings)
        try Data((recoveryTest ? "# Today\nTime 12:00\ncontext\n- [ ] shower\n" : "# Today\n\nA journal entry saved on the computer.\n").utf8).write(to: root.appendingPathComponent("Today.md"))
        try await service.stageAll()
        _ = try await service.commitLocal(message: "Computer changes", authorName: "Example", authorEmail: "example@example.invalid")
        try await service.pushCurrentBranch(pat: "")
        try await service.switchBranch(name: branch)
        try Data((taskTest ? "# Tasks\n- [x] Stretch\n- [ ] Walk\n" : "{\"fontSize\":20}\n").utf8).write(to: settings)
        try await service.stageAll()
        _ = try await service.commitLocal(message: "Phone changes", authorName: "Example", authorEmail: "example@example.invalid")
        do { _ = try await service.mergeBranch(name: "server", authorName: "Example", authorEmail: "example@example.invalid") }
        catch LocalGitError.mergeConflictsDetected { }
        var safetyReview: SyncSafetyReview?
        if recoveryTest {
            try await service.resolveConflict(path: conflictPath, strategy: .theirs)
            _ = try await service.completeMerge(message: "Combine notes", authorName: "Example", authorEmail: "example@example.invalid")
            try Data("# Today\ncontext\n- [x] shower\n".utf8).write(to: root.appendingPathComponent("Today.md"))
            do { try await service.stageAll() }
            catch LocalGitError.suspiciousChanges(let review) { safetyReview = review }
        }
        let info = try await service.repoInfo()
        let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let repo = RepoConfig(repoURL: "https://example.invalid/practice-vault.git", branch: branch,
            authorName: "Example", authorEmail: "example@example.invalid", vaultFolderName: "Practice vault",
            customVaultBookmarkData: bookmark, gitState: GitState(commitSHA: info.commitSHA, treeSHA: "", branch: branch, blobSHAs: [:], lastSyncDate: .distantPast), autoSyncEnabled: false)
        state.repos = [repo]
        if let safetyReview { state.safetyReviewByRepo[repo.id] = safetyReview }
        state.validateClonedRepos()
        _ = try await state.inspectRepositoryForVaultBridge(repoID: repo.id)
        await state.loadConflictSession(repoID: repo.id)
    }
}
#endif
