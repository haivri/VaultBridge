import SwiftUI

struct FileRecoveryView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    @State private var latestMerge: GitCommitSummary?
    var body: some View {
        List {
            Section {
                Text("Choose a saved checkpoint, then a file to recover. For a merge, you can restore the iPhone or incoming original from before your choice. Your current file is protected first.")
            }
            if let latestMerge {
                Section("Changed your mind about a merge?") {
                    NavigationLink("Recover a file from before the latest merge") {
                        RecoveryFilesView(repoID: repoID, commit: latestMerge)
                    }
                    Text("Choose the file, then its iPhone or incoming original. This restores only that file.").font(.caption)
                }
            }
            ForEach(state.commitHistoryByRepo[repoID] ?? []) { commit in
                NavigationLink {
                    RecoveryFilesView(repoID: repoID, commit: commit)
                } label: {
                    VStack(alignment: .leading) {
                        Text(commit.authoredDate, style: .date)
                        Text(commit.authoredDate, style: .time).foregroundStyle(.secondary)
                        Text(commit.message).font(.caption).lineLimit(2)
                    }
                }
            }
            if state.commitHistoryHasMoreByRepo[repoID] == true {
                Button("Earlier checkpoints") { Task { await state.loadCommitHistory(repoID: repoID) } }
            }
        }
        .navigationTitle("Recover previous work")
        .task {
            await state.loadCommitHistory(repoID: repoID, reset: true)
            for commit in (state.commitHistoryByRepo[repoID] ?? []).prefix(20) {
                guard !Task.isCancelled else { return }
                if let detail = try? await state.serializedRepository(repoID: repoID).commitDetail(oid: commit.oid), detail.parentOIDs.count == 2 {
                    latestMerge = commit; break
                }
            }
        }
    }
}

private struct RecoveryFilesView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    let commit: GitCommitSummary
    @State private var detail: GitCommitDetail?
    @State private var selection: GitCommitFileChange?
    @State private var result: String?
    @State private var busy = false
    var body: some View {
        List {
            if let result { Text(result) }
            if let detail {
                Text("Files changed in this checkpoint").font(.headline)
                ForEach(detail.changedFiles, id: \.path) { file in
                    Button(file.path) { selection = file }.disabled(busy)
                }
            } else { ProgressView("Loading checkpoint") }
        }
        .navigationTitle("Choose a file")
        .task {
            do { detail = try await state.serializedRepository(repoID: repoID).commitDetail(oid: commit.oid) }
            catch { result = "This checkpoint could not be read. Your files have not changed." }
        }
        .confirmationDialog("Restore this file?", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let file = selection, let detail {
                if detail.parentOIDs.count == 2 {
                    Button("Restore iPhone original before merge") { restore(file, from: detail.parentOIDs[0]) }
                    Button("Restore incoming original before merge") { restore(file, from: detail.parentOIDs[1]) }
                }
                Button("Restore version at this checkpoint") {
                    restore(file, from: file.changeType == .deleted ? detail.parentOIDs.first ?? commit.oid : commit.oid)
                }
                Button("Cancel", role: .cancel) { selection = nil }
            }
        } message: { Text("This replaces the entire file with the selected original, including older checkboxes and text. The current file will be protected first. Nothing uploads until you sync.") }
    }
    private func restore(_ file: GitCommitFileChange, from source: String) {
        selection = nil; busy = true
        Task {
            do {
                try await state.serializedRepository(repoID: repoID).restoreFile(path: file.path, from: source)
                state.detectChanges(repoID: repoID)
                result = "File restored on this iPhone. Sync when you’re ready to upload it."
            } catch { result = error.localizedDescription }
            busy = false
        }
    }

}
