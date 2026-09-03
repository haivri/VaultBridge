import SwiftUI

struct VaultView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultBridgeSyncCoordinator.self) private var syncCoordinator
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID

    @State private var showSettings = false
    @State private var showCommitSheet = false
    @State private var showChangedFiles = true
    @State private var showRevertAllConfirm = false
    @State private var revertFilePath: String? = nil
    @State private var showRevertFileModal = false
    @State private var showGitTools = false
    @State private var showReplaceConfirmation = false
    @State private var showSafeMergeConfirmation = false
    @State private var replaceConfirmation = ""

    private var repo: RepoConfig? { state.repo(id: repoID) }
    private var changeCount: Int { state.changeCounts[repoID] ?? 0 }
    private var statusEntries: [GitStatusEntry] { state.statusEntriesByRepo[repoID] ?? [] }
    private var syncState: RepoSyncState { state.syncStateByRepo[repoID] ?? .unknown }
    private var pullOutcome: PullOutcomeState? { state.pullOutcomeByRepo[repoID] }
    private var isThisRepoSyncing: Bool { state.isSyncing && state.syncingRepoID == repoID }

    private var callbackResult: CallbackResultState? {
        guard let result = state.callbackResult, result.repoID == repoID else { return nil }
        return result
    }

    var body: some View {
        @Bindable var state = state

        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let repo = repo {
                if repo.isCloned {
                    clonedContent(repo)
                } else if isThisRepoSyncing {
                    cloningContent
                } else {
                    notClonedContent
                }
            } else {
                ContentUnavailableView(
                    String(localized: "Repository Not Found"),
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let repo = repo {
                    Text(repo.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brutalText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showCommitSheet) { GitControlSheet(repoID: repoID) }
        .sheet(isPresented: $showSettings) { VaultBridgeRepoSettingsView(repoID: repoID) }
        .navigationDestination(for: DiffDestination.self) { dest in
            FileDiffView(repoID: dest.repoID, path: dest.path)
        }
        .navigationDestination(for: ConflictEditorDestination.self) { dest in
            ConflictEditorView(repoID: dest.repoID, path: dest.path)
        }
        .navigationDestination(for: FileBrowserDestination.self) { dest in
            FileBrowserView(repoID: dest.repoID, relativePath: dest.relativePath)
                .id(dest)
        }
        .navigationDestination(for: FileEditorDestination.self) { dest in
            FileEditorView(repoID: dest.repoID, fileURL: dest.fileURL)
        }
        .overlay {
            if showRevertAllConfirm {
                RevertConfirmModal(
                    title: String(localized: "Revert All Changes"),
                    filename: nil,
                    files: sortedStatusEntries.map(\.path),
                    confirmLabel: String(localized: "Revert All"),
                    onConfirm: {
                        showRevertAllConfirm = false
                        Task { await state.discardAllFileChanges(repoID: repoID) }
                    },
                    onCancel: { showRevertAllConfirm = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if showRevertFileModal, let path = revertFilePath {
                RevertConfirmModal(
                    title: String(localized: "Revert Changes"),
                    filename: URL(fileURLWithPath: path).lastPathComponent,
                    files: [],
                    confirmLabel: String(localized: "Revert"),
                    onConfirm: {
                        showRevertFileModal = false
                        let p = path
                        revertFilePath = nil
                        Task { await state.discardFileChanges(repoID: repoID, path: p) }
                    },
                    onCancel: {
                        showRevertFileModal = false
                        revertFilePath = nil
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showRevertAllConfirm)
        .animation(.easeOut(duration: 0.18), value: showRevertFileModal)
        .alert("Error", isPresented: $state.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastError ?? String(localized: "Unknown error"))
        }
        .alert("Replace Phone Copy with Server Copy?", isPresented: $showReplaceConfirmation) {
            TextField("Type REPLACE", text: $replaceConfirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Replace", role: .destructive) {
                guard replaceConfirmation == "REPLACE" else { return }
                replaceConfirmation = ""
                Task { await state.replacePhoneCopyWithServer(repoID: repoID) }
            }
            .disabled(replaceConfirmation != "REPLACE")
            Button("Cancel", role: .cancel) { replaceConfirmation = "" }
        } message: {
            Text("VaultBridge will first preserve the current commit and all dirty or untracked files, verify that recovery exists, and only then replace this phone's files. The server is never force-pushed.")
        }
        .alert("Combine Phone and Server Safely?", isPresented: $showSafeMergeConfirmation) {
            Button("Save & Combine") {
                Task { await state.mergeWithRemote(repoID: repoID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VaultBridge will create a local restore point, temporarily shelter any files that are still changing, download the server history, combine it on this iPhone, and restore the sheltered edits. Nothing is uploaded. Any conflict will stop for your choice.")
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: MarketingCapture.showGitSheetNotification)) { _ in
            showCommitSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MarketingCapture.showSettingsNotification)) { _ in
            showSettings = true
        }
        #endif
        .interactiveDismissDisabled(state.callbackNavigateToRepoID != nil)
        .navigationBarBackButtonHidden(state.callbackNavigateToRepoID != nil)
        .onAppear {
            #if DEBUG
            guard !MarketingCapture.isActive else { return }
            #endif
            // The dashboard normally inspected this same repository moments
            // ago. Reuse that result on navigation instead of traversing the
            // entire vault a second time; explicit refresh and Git actions
            // still request fresh status immediately.
            state.detectChanges(repoID: repoID, skipIfRecentlyStartedWithin: 60)
        }
        .onChange(of: state.repos) {
            if state.repo(id: repoID) == nil { dismiss() }
        }
        .refreshable { await syncCoordinator.sync(repoID: repoID, using: state) }
    }

    // MARK: - Cloned Content

    private func clonedContent(_ repo: RepoConfig) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                statusHeroCard(repo)
                if repo.assist.enabled || repo.assist.health.kind != .never {
                    assistHealthCard(repo.assist.health)
                }
                repoHealthCard
                if !statusEntries.isEmpty {
                    changedFilesCard
                }
                recommendedActionSection
                gitToolsSection

                if isThisRepoSyncing {
                    syncProgressCard
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }

                if let result = callbackResult {
                    callbackResultBanner(result)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                filesLocationCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .animation(.easeInOut(duration: 0.25), value: isThisRepoSyncing)
            .animation(.easeInOut(duration: 0.25), value: callbackResult)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Status Hero Card

    private func statusHeroCard(_ repo: RepoConfig) -> some View {
        BCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.displayName)
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(Color.brutalText)

                        if let owner = repo.ownerName {
                            Text(owner.uppercased())
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalText)
                                .tracking(1)
                        }
                    }

                    Spacer()

                    BBadge(text: syncStateLabel, style: syncStateBadgeStyle)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)


                HStack(spacing: 0) {
                    metaChip(icon: "arrow.triangle.branch", text: repo.gitState.branch, mono: true)
                    Spacer()
                    metaChip(icon: "number", text: String(repo.gitState.commitSHA.prefix(7)), mono: true)
                    Spacer()
                    metaChip(icon: "clock", text: lastSyncText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var lastSyncText: String {
        guard let repo else { return String(localized: "Never") }
        if repo.gitState.lastSyncDate == .distantPast { return String(localized: "Never") }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: repo.gitState.lastSyncDate, relativeTo: Date())
    }

    private var syncStateLabel: String {
        switch state.syncStateByRepo[repoID] ?? .unknown {
        case .upToDate: return String(localized: "Up to date")
        case .ahead:    return String(localized: "Local ahead")
        case .behind:   return String(localized: "Behind remote")
        case .diverged: return String(localized: "Diverged")
        case .unknown:  return String(localized: "Unknown")
        }
    }

    private var syncStateBadgeStyle: BBadge.BBadgeStyle {
        switch state.syncStateByRepo[repoID] ?? .unknown {
        case .upToDate: return .success
        case .ahead:    return .warning
        case .behind:   return .accent
        case .diverged: return .error
        case .unknown:  return .default
        }
    }

    private func metaChip(icon: String, text: String, mono: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brutalText)
            Text(text)
                .font(mono
                    ? .system(size: 13, weight: .medium, design: .monospaced)
                    : .system(size: 13, weight: .medium)
                )
                .foregroundStyle(Color.brutalText)
        }
    }

    // MARK: - Assist Health

    private func assistHealthCard(_ health: RepoAssistHealth) -> some View {
        BCard(padding: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: health.kind == .attention || health.kind == .failed
                      ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle.fill")
                    .foregroundStyle(health.kind == .attention || health.kind == .failed
                                     ? Color.brutalWarning : Color.brutalSuccess)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GITSYNC ASSIST")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1)
                    Text(assistHealthLabel(health))
                        .font(.system(size: 14, weight: .semibold))
                    if let message = health.message {
                        Text(message).font(.system(size: 12, design: .monospaced))
                    }
                    if let attempt = health.lastAttemptDate {
                        Text("Last attempt \(assistRelativeDate(attempt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(16)
        }
    }

    private func assistHealthLabel(_ health: RepoAssistHealth) -> String {
        switch health.kind {
        case .never: "Waiting for first wake"
        case .updated: "Fast-forwarded"
        case .upToDate: "Up to date"
        case .deferred: "Deferred by policy"
        case .attention: "Attention required"
        case .failed: "Last attempt failed"
        }
    }

    private func assistRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Repo Health

    private var repoHealthCard: some View {
        BCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    BSectionHeader(title: String(localized: "Repo Health"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)


                HStack(spacing: 12) {
                    healthPill(label: String(localized: "Changed"), count: statusEntries.count)
                    healthPill(label: String(localized: "Conflicts"), count: conflictedFileCount, style: conflictedFileCount > 0 ? .error : .default)
                    healthPill(label: String(localized: "Untracked"), count: untrackedFileCount, style: untrackedFileCount > 0 ? .accent : .default)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let outcome = pullOutcome {

                    HStack(spacing: 10) {
                        Image(systemName: pullOutcomeIcon(outcome.kind))
                            .font(.system(size: 13))
                            .foregroundStyle(pullOutcomeColor(outcome.kind))
                        Text(outcome.message)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.brutalText)
                        Spacer()

                        if outcome.kind == .blockedByLocalChanges {
                            Button {
                                saveLocally()
                            } label: {
                                Text(String(localized: "Save locally").uppercased())
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.brutalAccent)
                                    .tracking(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .overlay(Rectangle().strokeBorder(Color.brutalAccent.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isSyncing)
                        }

                        if outcome.kind == .diverged {
                            Button {
                                showSafeMergeConfirmation = true
                            } label: {
                                Text(String(localized: "Merge").uppercased())
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.brutalError)
                                    .tracking(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .overlay(Rectangle().strokeBorder(Color.brutalError.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isSyncing)

                            Button {
                                Task { await state.pullWithRebase(repoID: repoID) }
                            } label: {
                                Text(String(localized: "Rebase").uppercased())
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.brutalAccent)
                                    .tracking(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .overlay(Rectangle().strokeBorder(Color.brutalAccent.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isSyncing)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var conflictedFileCount: Int { statusEntries.filter(\.isConflicted).count }
    private var untrackedFileCount: Int { statusEntries.filter { $0.workTreeStatus == .untracked }.count }

    private func healthPill(label: String, count: Int, style: BBadge.BBadgeStyle = .`default`) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .foregroundStyle(style.fg)
            Text(label.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalText)
                .tracking(1)
        }
    }

    private func pullOutcomeIcon(_ kind: PullOutcomeKind) -> String {
        switch kind {
        case .upToDate:              return "checkmark.circle.fill"
        case .fastForwarded:         return "arrow.down.circle.fill"
        case .rebased:               return "arrow.triangle.2.circlepath.circle.fill"
        case .rebaseConflicts:       return "exclamationmark.triangle.fill"
        case .blockedByLocalChanges: return "exclamationmark.triangle.fill"
        case .diverged:              return "arrow.triangle.branch"
        case .remoteBranchMissing:   return "questionmark.circle.fill"
        case .failed:                return "xmark.circle.fill"
        }
    }

    private func pullOutcomeColor(_ kind: PullOutcomeKind) -> Color {
        switch kind {
        case .upToDate:              return .brutalSuccess
        case .fastForwarded:         return .brutalAccent
        case .rebased:               return .brutalSuccess
        case .rebaseConflicts:       return .brutalWarning
        case .blockedByLocalChanges: return .brutalWarning
        case .diverged:              return .brutalError
        case .remoteBranchMissing:   return .brutalWarning
        case .failed:                return .brutalError
        }
    }

    // MARK: - Changed Files

    private var sortedStatusEntries: [GitStatusEntry] {
        statusEntries.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var changedFilesCard: some View {
        BCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    // Collapse toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showChangedFiles.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            BSectionHeader(title: String(localized: "Changed Files"))
                            BBadge(text: "\(statusEntries.count)", style: .accent)
                            Image(systemName: showChangedFiles ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.brutalText)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Revert all
                    Button {
                        showRevertAllConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .bold))
                            Text(String(localized: "All").uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1)
                        }
                        .foregroundStyle(Color.brutalError)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(Rectangle().strokeBorder(Color.brutalError.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if showChangedFiles {
                    let entries = sortedStatusEntries

                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            changedFileRow(entry)
                            if index < entries.count - 1 {
                                BDivider().padding(.horizontal, 16)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func changedFileRow(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 0) {
            // Tapping the row navigates: conflicts → resolve conflict view, otherwise → diff
            Group {
                if entry.isConflicted {
                    NavigationLink(value: ConflictEditorDestination(repoID: repoID, path: entry.path)) {
                        changedFileRowContent(entry)
                    }
                } else {
                    NavigationLink(value: DiffDestination(repoID: repoID, path: entry.path)) {
                        changedFileRowContent(entry)
                    }
                }
            }
            .buttonStyle(.plain)

            // Per-file revert
            Button {
                revertFilePath = entry.path
                showRevertFileModal = true
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brutalError)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func changedFileRowContent(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.path)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.brutalText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileStatusSummary(for: entry))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.brutalText.opacity(0.6))
            }
            Spacer(minLength: 8)
            fileStatusBadge(for: entry)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brutalText.opacity(0.3))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 11)
    }

    private func fileStatusSummary(for entry: GitStatusEntry) -> String {
        switch (entry.indexStatus, entry.workTreeStatus) {
        case let (index?, workTree?): return String(localized: "Staged \(fileStatusLabel(index))") + " · " + String(localized: "Unstaged \(fileStatusLabel(workTree))")
        case let (index?, nil):       return String(localized: "Staged \(fileStatusLabel(index))")
        case let (nil, workTree?):    return fileStatusLabel(workTree).capitalized
        case (nil, nil):              return String(localized: "No status")
        }
    }

    private func fileStatusLabel(_ kind: GitFileStatusKind) -> String {
        switch kind {
        case .added:       return String(localized: "added")
        case .modified:    return String(localized: "modified")
        case .deleted:     return String(localized: "deleted")
        case .renamed:     return String(localized: "renamed")
        case .typeChanged: return String(localized: "type changed")
        case .untracked:   return String(localized: "untracked")
        case .conflicted:  return String(localized: "conflicted")
        }
    }

    @ViewBuilder
    private func fileStatusBadge(for entry: GitStatusEntry) -> some View {
        if entry.isConflicted {
            BBadge(text: String(localized: "Conflict"), style: .error)
        } else if let index = entry.indexStatus {
            BBadge(text: fileStatusLabel(index), style: .success)
        } else if let work = entry.workTreeStatus {
            BBadge(text: fileStatusLabel(work), style: work == .untracked ? .accent : .default)
        }
    }

    // MARK: - Sync Actions

    private var primaryAction: VaultBridgePrimaryAction {
        .choose(changeCount: changeCount, syncState: syncState, conflictCount: conflictedFileCount)
    }

    private var recommendedActionSection: some View {
        BCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localSafetyTitle)
                        .font(.system(size: 16, weight: .bold))
                    Text(localSafetyDetail)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.brutalTextMid)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                BDivider()

                Button { performPrimaryAction() } label: {
                    BActionRow(
                        icon: primaryAction.systemImage,
                        title: primaryAction.title,
                        subtitle: primaryAction.gitSubtitle,
                        badge: primaryAction == .resolveConflicts ? conflictedFileCount : nil,
                        badgeStyle: primaryAction == .resolveConflicts ? .error : .accent
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.isSyncing)
                .opacity(state.isSyncing ? 0.5 : 1)
            }
        }
    }

    private var localSafetyTitle: String {
        if changeCount > 0 { return "\(changeCount) change\(changeCount == 1 ? "" : "s") not saved in Git yet" }
        if syncState == .ahead { return "Saved on this iPhone — not uploaded yet" }
        return "Saved locally" + (syncState == .upToDate ? " and on the server" : "")
    }

    private var localSafetyDetail: String {
        guard let repo, !repo.gitState.commitSHA.isEmpty else { return "No local checkpoint has been created yet." }
        let phoneAge = relativeAge(repo.gitState.localCheckpointDate) ?? "present on this phone"
        let serverSHA = repo.gitState.remoteCommitSHA.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "not checked"
        let serverAge = relativeAge(repo.gitState.lastRemoteCheckDate) ?? "open Check Again to verify"
        return "PHONE  \(repo.gitState.commitSHA.prefix(7)) • \(phoneAge)\nSERVER \(serverSHA) • \(serverAge)"
    }

    private func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var gitToolsSection: some View {
        BCard(padding: 0) {
            DisclosureGroup(isExpanded: $showGitTools) {
                VStack(spacing: 0) {
                    BDivider()
                    gitToolButton("Save a Restore Point on This iPhone", subtitle: "Saves every settled phone edit locally and shows the commit ID. Does not upload.", icon: "internaldrive") {
                        saveLocally()
                    }
                    BDivider()
                    gitToolButton("Bring Newer Server Files to This Phone", subtitle: "Only when the phone has no competing saved history. Does not upload or rewrite anything.", icon: "arrow.down") {
                        Task { _ = await state.pullOnly(repoID: repoID, showsProgressDelay: false) }
                    }
                    BDivider()
                    gitToolButton("Put Phone Work After Server Work", subtitle: "Advanced: reorders only unuploaded phone commits on top of the latest server commits.", icon: "arrow.triangle.2.circlepath") {
                        Task { await state.pullWithRebase(repoID: repoID, showsProgressDelay: false) }
                    }
                    BDivider()
                    gitToolButton("Combine Phone and Server Histories", subtitle: "Saves the phone first, shelters active edits, and combines both histories here. Does not upload.", icon: "arrow.triangle.merge") {
                        showSafeMergeConfirmation = true
                    }
                    BDivider()
                    gitToolButton("Upload This Phone’s Saved Work", subtitle: "Sends local commits to the server after checking it is safe. Never force-overwrites server work.", icon: "arrow.up") {
                        Task { await state.pushCurrentBranch(repoID: repoID) }
                    }
                    BDivider()
                    gitToolButton("Expert Git Tools & Recovery", subtitle: "Inspect history, alternate branches, temporary shelves, tags, and conflict recovery.", icon: "wrench.and.screwdriver") {
                        showCommitSheet = true
                    }
                    if let recovery = state.recoveryByRepo[repoID] {
                        BDivider()
                        gitToolButton("Restore Protected Phone Backup", subtitle: "Returns to phone commit \(recovery.commitSHA.prefix(7)) and restores its sheltered edits. Review afterward.", icon: "arrow.uturn.backward.circle") {
                            Task { await state.restoreProtectedRecovery(repoID: repoID) }
                        }
                    }
                    BDivider()
                    gitToolButton("Emergency: Make Phone Match Server", subtitle: "First creates and verifies a recovery backup, then replaces phone files. Never changes the server.", icon: "externaldrive.badge.exclamationmark") {
                        replaceConfirmation = ""
                        showReplaceConfirmation = true
                    }
                }
            } label: {
                Label("Git Tools & Recovery", systemImage: "terminal")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.brutalText)
                    .padding(16)
            }
            .tint(Color.brutalAccent)
        }
    }

    private func gitToolButton(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            BActionRow(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
        .disabled(state.isSyncing)
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .saveOnPhone: saveLocally()
        case .getServerUpdates:
            Task { _ = await state.pullOnly(repoID: repoID, showsProgressDelay: false) }
        case .uploadSavedChanges:
            Task { await state.pushCurrentBranch(repoID: repoID) }
        case .combineChanges:
            showSafeMergeConfirmation = true
        case .resolveConflicts:
            showCommitSheet = true
        case .checkAgain:
            Task { await syncCoordinator.sync(repoID: repoID, using: state) }
        }
    }

    private func saveLocally() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        Task {
            _ = await state.commitAllLocallyForVaultBridgeWithUI(
                repoID: repoID,
                message: "VaultBridge local checkpoint \(stamp)"
            )
        }
    }

    // MARK: - Sync Progress

    private var syncProgressCard: some View {
        BCard(padding: 14, bg: .brutalSurface) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.brutalAccent)
                Text(state.syncProgress.uppercased())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.brutalText)
                    .tracking(1)
                Spacer()
            }
        }
    }

    // MARK: - Callback Result

    private func callbackResultBanner(_ result: CallbackResultState) -> some View {
        BCard(padding: 14, bg: result.isSuccess ? Color.brutalSuccess.opacity(0.04) : Color.brutalError.opacity(0.04)) {
            HStack(spacing: 12) {
                BBadge(text: result.isSuccess ? String(localized: "Success") : String(localized: "Failed"), style: result.isSuccess ? .success : .error)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.isSuccess
                         ? String(localized: "\(result.action.capitalized) Complete")
                         : String(localized: "\(result.action.capitalized) Failed"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.brutalText)

                    Text(result.message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.brutalText)
                        .lineLimit(2)
                }

                Spacer()

                if result.isSuccess {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.brutalText)
                }
            }
        }
    }

    // MARK: - Files Location

    private var filesLocationCard: some View {
        BCard(padding: 0) {
            VStack(spacing: 0) {
                NavigationLink(value: FileBrowserDestination(repoID: repoID, relativePath: "")) {
                    BActionRow(
                        icon: "folder",
                        title: String(localized: "Browse Files"),
                        subtitle: String(localized: "Delete, rename, and move files")
                    )
                }
                .buttonStyle(.plain)

                BDivider()

                Button { openInFilesApp() } label: {
                    BActionRow(
                        icon: "folder.badge.gearshape",
                        title: String(localized: "Open in Files"),
                        subtitle: String(localized: "Open repository in Files app")
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func openInFilesApp() {
        let vaultDir = state.vaultURL(for: repoID)
        let filesURL = URL(string: "shareddocuments://\(vaultDir.path)")
        if let filesURL, UIApplication.shared.canOpenURL(filesURL) {
            UIApplication.shared.open(filesURL)
        }
    }

    // MARK: - Cloning In Progress

    private var cloningContent: some View {
        VStack(spacing: 24) {
            Spacer()

            BLoading(text: String(localized: "Cloning Repository"))

            Text(state.syncProgress)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.brutalText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            BProgressBar(progress: 0.5)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Not Cloned

    private var notClonedContent: some View {
        VStack(spacing: 24) {
            Spacer()

            BEmptyState(
                title: String(localized: "Not Cloned"),
                subtitle: String(localized: "This repository hasn't been cloned yet.\nTap below to download it."),
                actionTitle: String(localized: "Clone Repository")
            ) {
                Task { await state.clone(repoID: repoID) }
            }

            Spacer()
            Spacer()
        }
    }
}
