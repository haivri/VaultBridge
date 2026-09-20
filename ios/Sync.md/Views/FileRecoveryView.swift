import SwiftUI

struct FileRecoveryView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    var body: some View {
        List {
            Section { Text("Choose a saved checkpoint, then a file to recover. Your current file is protected before its previous version is restored.") }
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
        .task { await state.loadCommitHistory(repoID: repoID, reset: true) }
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
            Button("Restore protected version") {
                guard let file = selection, let detail else { return }
                let source = file.changeType == .deleted ? detail.parentOIDs.first ?? commit.oid : commit.oid
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
        } message: { Text("The current file will be protected first. Restoring changes only this iPhone; it does not upload anything.") }
    }
}
