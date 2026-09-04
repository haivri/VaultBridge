import SwiftUI

struct VaultView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultBridgeSyncCoordinator.self) private var syncCoordinator
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID

    @State private var showSettings = false
    @State private var showCommitSheet = false
    @State private var showChangedFiles = true
    @State private var showGitTools = false
    @State private var showReplaceConfirmation = false
    @State private var showSafeMergeConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var replaceConfirmation = ""

    private var repo: RepoConfig? { state.repo(id: repoID) }
    private var changeCount: Int { state.changeCounts[repoID] ?? 0 }
    private var statusEntries: [GitStatusEntry] { state.statusEntriesByRepo[repoID] ?? [] }
    private var syncState: RepoSyncState { state.syncStateByRepo[repoID] ?? .unknown }
    private var lastResult: PullOutcomeState? { state.pullOutcomeByRepo[repoID] }
    private var shelteredEdits: VaultBridgeShelteredEdits? { state.shelteredEditsByRepo[repoID] }
    private var coordinatorStatus: VaultBridgeSyncStatus { syncCoordinator.status(for: repoID) }
    private var isThisRepoSyncing: Bool { state.isSyncing && state.syncingRepoID == repoID }
    /// Every button on this screen keys off one busy flag so a tap can never
    /// start a second workflow while the automatic one is between steps.
    private var isBusy: Bool { state.isSyncing || syncCoordinator.isSyncingAll || coordinatorStatus.isRunning }

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
            Text("VaultBridge checks the server first, then protects the current phone commit and every unsaved file, and only then replaces this phone's files. The server is never changed. The previous phone state can be restored from Git Tools.")
        }
        .alert("Restore Protected Phone Backup?", isPresented: $showRestoreConfirmation) {
            Button("Restore") {
                Task { await state.restoreProtectedRecovery(repoID: repoID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let recovery = state.recoveryByRepo[repoID] {
                Text("This phone returns to commit \(recovery.commitSHA.prefix(7)) and its sheltered edits. The files you have now are protected first, so this can be undone. Nothing is uploaded.")
            } else {
                Text("No protected backup is available.")
            }
        }
        .alert("Combine Phone and Server?", isPresented: $showSafeMergeConfirmation) {
            Button("Combine") {
                Task { await state.mergeWithRemote(repoID: repoID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("VaultBridge checks the server, saves this phone, shelters any notes still being written, combines both histories here, and puts the sheltered notes back. Nothing is uploaded. A conflict stops for your choice.")
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
                if let shelteredEdits {
                    shelteredEditsCard(shelteredEdits)
                }
                syncCard
                if !statusEntries.isEmpty {
                    changedFilesCard
                }
                gitToolsSection

                if let result = callbackResult {
                    callbackResultBanner(result)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                filesLocationCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .animation(.easeInOut(duration: 0.25), value: isBusy)
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

                    BBadge(text: vaultStateLabel, style: vaultStateBadgeStyle)
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

    /// Plain-language vault state. Git terms stay in the expert drawer.
    private var vaultStateLabel: String {
        if conflictedFileCount > 0 { return String(localized: "Needs your choice") }
        if changeCount > 0 { return String(localized: "Unsaved edits") }
        switch syncState {
        case .upToDate: return String(localized: "Synced")
        case .ahead:    return String(localized: "Not uploaded yet")
        case .behind:   return String(localized: "Server has updates")
        case .diverged: return String(localized: "Needs combining")
        case .unknown:  return String(localized: "Not checked")
        }
    }

    private var vaultStateBadgeStyle: BBadge.BBadgeStyle {
        if conflictedFileCount > 0 { return .error }
        if changeCount > 0 { return .accent }
        switch syncState {
        case .upToDate: return .success
        case .ahead:    return .warning
        case .behind:   return .accent
        case .diverged: return .warning
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
                        Text("Last attempt \(relativeAge(attempt) ?? "")")
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
        case .updated: "Brought server updates"
        case .upToDate: "Up to date"
        case .deferred: "Deferred by policy"
        case .attention: "Attention required"
        case .failed: "Last attempt failed"
        }
    }

    // MARK: - Sheltered Edits

    private func shelteredEditsCard(_ sheltered: VaultBridgeShelteredEdits) -> some View {
        BCard(padding: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(Color.brutalWarning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHELTERED EDITS")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1)
                    Text("Some of your edits were set aside \(relativeAge(sheltered.createdAt) ?? "recently") and are not in the vault yet. \(sheltered.reason). Sync Now puts them back.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.brutalTextMid)
                }
                Spacer()
                Button {
                    Task { await state.restoreShelteredEdits(repoID: repoID) }
                } label: {
                    Text(String(localized: "Put back").uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brutalAccent)
                        .tracking(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(Rectangle().strokeBorder(Color.brutalAccent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
            .padding(16)
        }
    }

    // MARK: - Sync Card

    private var conflictedFileCount: Int { statusEntries.filter(\.isConflicted).count }

    private var primaryAction: VaultBridgePrimaryAction {
        .choose(conflictCount: conflictedFileCount)
    }

    private var syncCard: some View {
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

                if isBusy {
                    BDivider()
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.brutalAccent)
                        Text(progressText.uppercased())
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalText)
                            .tracking(1)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else if let result = lastResult {
                    BDivider()
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: result.kind.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(toneColor(result.kind.tone))
                        Text(result.message)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.brutalText)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else if coordinatorStatus.phase != .idle {
                    BDivider()
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: coordinatorStatus.phase == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(coordinatorStatus.phase == .complete ? Color.brutalSuccess : Color.brutalWarning)
                        Text(coordinatorStatus.message)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.brutalText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                BDivider()

                Button { performPrimaryAction() } label: {
                    BActionRow(
                        icon: primaryAction.systemImage,
                        title: primaryAction.title,
                        subtitle: primaryAction.subtitle,
                        badge: primaryAction == .resolveConflicts ? conflictedFileCount : nil,
                        badgeStyle: .error
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
    }

    private var progressText: String {
        if coordinatorStatus.isRunning { return coordinatorStatus.message }
        if isThisRepoSyncing, !state.syncProgress.isEmpty { return state.syncProgress }
        return String(localized: "Working")
    }

    private func toneColor(_ tone: PullOutcomeKind.Tone) -> Color {
        switch tone {
        case .success: .brutalSuccess
        case .info: .brutalAccent
        case .attention: .brutalWarning
        case .failure: .brutalError
        case .neutral: .brutalTextMid
        }
    }

    private var localSafetyTitle: String {
        if conflictedFileCount > 0 {
            return conflictedFileCount == 1
                ? "1 note needs your choice"
                : "\(conflictedFileCount) notes need your choice"
        }
        if changeCount > 0 { return "\(changeCount) change\(changeCount == 1 ? "" : "s") not saved yet" }
        switch syncState {
        case .ahead: return "Saved on this iPhone, not uploaded yet"
        case .upToDate: return "Saved on this iPhone and on the server"
        case .behind: return "Saved on this iPhone. The server has newer notes"
        case .diverged: return "Saved on this iPhone. The server also has new notes"
        case .unknown: return "Saved on this iPhone"
        }
    }

    private var localSafetyDetail: String {
        guard let repo, !repo.gitState.commitSHA.isEmpty else { return "Nothing has been saved on this phone yet." }
        let phoneAge = relativeAge(repo.gitState.localCheckpointDate) ?? "present on this phone"
        let serverSHA = repo.gitState.remoteCommitSHA.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "not checked"
        let serverAge = relativeAge(repo.gitState.lastRemoteCheckDate) ?? "not checked yet"
        return "PHONE  \(repo.gitState.commitSHA.prefix(7)) • \(phoneAge)\nSERVER \(serverSHA) • checked \(serverAge)"
    }

    private func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .syncNow:
            Task { await syncCoordinator.sync(repoID: repoID, using: state) }
        case .resolveConflicts:
            showCommitSheet = true
        }
    }

    // MARK: - Changed Files

    private var sortedStatusEntries: [GitStatusEntry] {
        statusEntries.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var changedFilesCard: some View {
        BCard(padding: 0) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChangedFiles.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        BSectionHeader(title: String(localized: "Changed Files"))
                        BBadge(text: "\(statusEntries.count)", style: conflictedFileCount > 0 ? .error : .accent)
                        Spacer()
                        Image(systemName: showChangedFiles ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brutalText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func fileStatusSummary(for entry: GitStatusEntry) -> String {
        if entry.isConflicted { return String(localized: "Changed on the phone and the server") }
        let kind = entry.workTreeStatus ?? entry.indexStatus
        switch kind {
        case .added, .untracked: return String(localized: "New note")
        case .modified:          return String(localized: "Edited")
        case .deleted:           return String(localized: "Deleted")
        case .renamed:           return String(localized: "Renamed")
        case .typeChanged:       return String(localized: "Changed")
        case .conflicted:        return String(localized: "Changed on the phone and the server")
        case nil:                return String(localized: "Changed")
        }
    }

    @ViewBuilder
    private func fileStatusBadge(for entry: GitStatusEntry) -> some View {
        if entry.isConflicted {
            BBadge(text: String(localized: "Choose"), style: .error)
        } else if entry.workTreeStatus == .untracked || entry.indexStatus == .added {
            BBadge(text: String(localized: "New"), style: .accent)
        } else if entry.workTreeStatus == .deleted || entry.indexStatus == .deleted {
            BBadge(text: String(localized: "Deleted"), style: .default)
        } else {
            BBadge(text: String(localized: "Edited"), style: .default)
        }
    }

    // MARK: - Git Tools

    private var gitToolsSection: some View {
        BCard(padding: 0) {
            DisclosureGroup(isExpanded: $showGitTools) {
                VStack(spacing: 0) {
                    BDivider()
                    gitToolButton("Save on This iPhone Only", subtitle: "Creates a restore point here and shows its ID. Does not upload.", icon: "internaldrive") {
                        saveLocally()
                    }
                    BDivider()
                    gitToolButton("Bring Newer Server Notes Here", subtitle: "Only when this phone has nothing unsaved and no competing work. Does not upload.", icon: "arrow.down") {
                        Task { _ = await state.pullOnly(repoID: repoID, showsProgressDelay: false) }
                    }
                    BDivider()
                    gitToolButton("Upload This iPhone's Saved Work", subtitle: "Checks the server first, then sends saved work. Never overwrites server work.", icon: "arrow.up") {
                        Task { await state.pushCurrentBranch(repoID: repoID) }
                    }
                    BDivider()
                    gitToolButton("Combine Phone and Server Here", subtitle: "Saves this phone, shelters notes still being written, and combines both histories. Does not upload.", icon: "arrow.triangle.merge") {
                        showSafeMergeConfirmation = true
                    }
                    BDivider()
                    gitToolButton("Advanced: Put Phone Work After Server Work", subtitle: "Rebase. Rewrites only unuploaded phone commits so they follow the server's. The phone commit ID changes.", icon: "arrow.triangle.2.circlepath") {
                        Task { await state.pullWithRebase(repoID: repoID, showsProgressDelay: false) }
                    }
                    BDivider()
                    gitToolButton("Expert Git Tools", subtitle: "History, branches, stashes, tags, revert, and conflict tools.", icon: "wrench.and.screwdriver") {
                        showCommitSheet = true
                    }
                    if let recovery = state.recoveryByRepo[repoID] {
                        BDivider()
                        gitToolButton("Restore Protected Phone Backup", subtitle: "Returns to phone commit \(recovery.commitSHA.prefix(7)) and its sheltered edits. Protects the current files first.", icon: "arrow.uturn.backward.circle") {
                            showRestoreConfirmation = true
                        }
                    }
                    BDivider()
                    gitToolButton("Emergency: Make Phone Match Server", subtitle: "Checks the server, protects the current phone state, then replaces phone files. Never changes the server.", icon: "externaldrive.badge.exclamationmark") {
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
        .disabled(isBusy)
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
