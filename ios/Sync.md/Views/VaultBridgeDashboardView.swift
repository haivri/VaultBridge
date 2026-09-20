import SwiftUI

struct VaultBridgeDashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultBridgeSyncCoordinator.self) private var syncCoordinator

    @State private var showAddRepo = false
    @State private var navigation: [UUID] = []
    @AppStorage("lastOpenedVault") private var lastOpenedVault = ""
    @State private var restoredNavigation = false
    @State private var settingsRepoID: UUID?
    @State private var lfsRepairRepoID: UUID?

    var body: some View {
        @Bindable var state = state

        NavigationStack(path: $navigation) {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if state.repos.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            overview
                            ForEach(state.repos.sorted { attentionCount($0.id) > attentionCount($1.id) }) { repo in
                                vaultCard(repo)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable {
                        await syncCoordinator.syncAll(using: state)
                    }
                }
            }
            .navigationTitle("VaultBridge")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddRepo = true
                    } label: {
                        Label("Add Vault", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddRepo) {
                AddRepoView()
            }
            .sheet(item: $settingsRepoID) { repoID in
                VaultBridgeRepoSettingsView(repoID: repoID)
            }
            .navigationDestination(for: UUID.self) { repoID in
                VaultView(repoID: repoID)
            }
            .alert("VaultBridge", isPresented: $state.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.lastError ?? "An unexpected Git error occurred.")
            }
            .confirmationDialog(
                "Repair large files for Git LFS?",
                isPresented: Binding(
                    get: { lfsRepairRepoID != nil },
                    set: { if !$0 { lfsRepairRepoID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Repair and Push") {
                    if let repoID = lfsRepairRepoID {
                        lfsRepairRepoID = nil
                        Task { await state.repairLargeFilesAndPush(repoID: repoID) }
                    }
                }
                Button("Cancel", role: .cancel) { lfsRepairRepoID = nil }
            } message: {
                Text("Unpushed commits containing large files will be rewritten so those files use Git LFS. Commit messages, authors, and every file are preserved, a backup ref keeps the current state recoverable, and nothing already on the remote is changed. The vault then pushes normally.")
            }
            .onChange(of: VaultBridgeNotificationRouter.shared.repoID) {
                if let id = VaultBridgeNotificationRouter.shared.repoID, state.repo(id: id) != nil { navigation = [id] }
            }
            .onChange(of: state.repos.count) {
                if navigation.isEmpty && state.repos.count == 1, let only = state.repos.first { navigation = [only.id] }
            }
            .onChange(of: navigation) {
                if let selected = navigation.last { lastOpenedVault = selected.uuidString }
            }
            .task {
                if !restoredNavigation {
                    restoredNavigation = true
                    if state.repos.count == 1, let only = state.repos.first { navigation = [only.id] }
                    else if let selected = UUID(uuidString: lastOpenedVault), state.repo(id: selected) != nil { navigation = [selected] }
                }
                await syncCoordinator.syncOnForeground(using: state)
            }
        }
    }

    private var overview: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your saved work")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summaryText)
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                Task { await syncCoordinator.syncAll(using: state) }
            } label: {
                if syncCoordinator.isSyncingAll {
                    ProgressView().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(syncCoordinator.isSyncingAll || state.isSyncing)
            .accessibilityLabel("Sync all vaults")
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func vaultCard(_ repo: RepoConfig) -> some View {
        let syncStatus = syncCoordinator.status(for: repo.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(statusColor(syncStatus.phase).opacity(0.14))
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(statusColor(syncStatus.phase))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(repo.autoSyncEnabled ? "Automatic sync enabled" : "Manual sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        settingsRepoID = repo.id
                    } label: {
                        Label("Vault Settings", systemImage: "gearshape")
                    }
                    Button {
                        Task { await syncCoordinator.sync(repoID: repo.id, using: state) }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    // sync(repoID:) bails silently while another operation is
                    // running; disable instead of accepting a dead tap.
                    .disabled(syncCoordinator.isSyncingAll || state.isSyncing || syncStatus.isRunning)
                    if state.pushErrorByRepo[repo.id]?.isLFSRepairEligible == true {
                        Button {
                            lfsRepairRepoID = repo.id
                        } label: {
                            Label("Repair Large Files…", systemImage: "arrow.up.doc.on.clipboard")
                        }
                        .disabled(syncCoordinator.isSyncingAll || state.isSyncing || syncStatus.isRunning)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }


            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(attentionCount(repo.id) > 0 ? "Files need your choice" : syncStatus.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor(syncStatus.phase))
                        .lineLimit(2)
                    Text(lastSyncText(repo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if syncStatus.isRunning {
                    ProgressView().controlSize(.small)
                }
                NavigationLink(value: repo.id) {
                    Text(attentionCount(repo.id) > 0 ? "Review" : "View vault")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Vaults Yet", systemImage: "externaldrive.badge.plus")
        } description: {
            Text("Clone a remote repository or connect an existing vault. Each vault keeps its own credentials and sync policy.")
        } actions: {
            Button("Add Vault") { showAddRepo = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var summaryText: String {
        let automatic = state.repos.filter(\.autoSyncEnabled).count
        let attention = state.repos.filter { attentionCount($0.id) > 0 }.count
        return attention > 0 ? "\(attention) vault\(attention == 1 ? " needs" : "s need") your attention" : "\(state.repos.count) vault\(state.repos.count == 1 ? "" : "s") · \(automatic) automatic"
    }

    private func attentionCount(_ id: UUID) -> Int {
        (state.conflictSessionByRepo[id]?.unmergedPaths.count ?? 0) + (state.safetyReviewByRepo[id]?.paths.count ?? 0)
    }

    private func localChanges(_ id: UUID) -> String {
        let count = state.changeCounts[id] ?? 0
        return count == 0 ? "Checkpoint saved" : "\(count) changes to sync"
    }

    private func remoteState(_ id: UUID) -> String {
        if state.shelteredEditsByRepo[id] != nil { return "Sheltered edits" }
        return switch state.syncStateByRepo[id] ?? .unknown {
        case .upToDate: "Synced"
        case .ahead: "Not uploaded"
        case .behind: "Server has updates"
        case .diverged: "Needs combining"
        case .unknown: "Not checked"
        }
    }

    private func statusPill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    private func statusColor(_ phase: VaultBridgeSyncPhase) -> Color {
        switch phase {
        case .complete: .green
        case .attention: .orange
        case .failed: .red
        case .inspecting, .committing, .fetching, .comparing, .reconciling, .pulling, .pushing, .verifying: .blue
        case .idle: .secondary
        }
    }

    private func lastSyncText(_ repo: RepoConfig) -> String {
        guard repo.gitState.lastSyncDate != .distantPast else { return "Never synced" }
        return "Last sync " + repo.gitState.lastSyncDate.formatted(.relative(presentation: .named))
    }
}
