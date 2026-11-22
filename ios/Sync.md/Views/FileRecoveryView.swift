import SwiftUI

struct FileRecoveryView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    @State private var latestMerge: GitCommitSummary?
    @State private var notes: [String] = []
    @State private var query = ""
    @State private var loadFailure: String?
    var body: some View {
        List {
            Section("Find a note") {
                ForEach(notes.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(100), id: \.self) { path in
                    NavigationLink(path) { RecoveryNoteVersionsView(repoID: repoID, path: path) }
                }
                if let loadFailure { Text(loadFailure).foregroundStyle(.red) }
                Text("Includes deleted notes. Search to narrow the list. Obsidian File Recovery snapshots are separate; open them in Obsidian Settings → File recovery.").font(.caption)
            }
            Section("Browse checkpoints") {
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
        .searchable(text: $query, prompt: "Find a note")
        .task {
            do { notes = try await state.serializedRepository(repoID: repoID).recoveryNotes() }
            catch { loadFailure = "Note history could not be loaded. Your files are unchanged." }
        }
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


struct RecoveryNoteVersionsView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    let path: String
    @State private var versions: [GitCommitSummary] = []
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            Text(path).font(.caption).textSelection(.enabled)
            ForEach(Array(versions.enumerated()), id: \.offset) { offset, version in
                NavigationLink {
                    NoteRecoveryPreviewView(repoID: repoID, path: path, commit: version.oid)
                } label: {
                    VStack(alignment: .leading) {
                        Text(version.authoredDate.formatted(date: .abbreviated, time: .standard))
                        Text(version.message).font(.caption)
                    }
                }.accessibilityIdentifier("recovery.version.\(offset)")
            }
            if let error { Text(error).foregroundStyle(.red) }
            if more { Button("Earlier versions") { Task { await load() } }.disabled(busy) }
            if busy { ProgressView() }
        }.navigationTitle("Note versions").task { if versions.isEmpty { await load() } }
    }
    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let next = try await state.serializedRepository(repoID: repoID).noteHistory(path: path, limit: 50, skip: versions.count)
            versions += next; more = next.count == 50
        } catch { self.error = error.localizedDescription }
    }
}

struct NoteRecoveryPreviewView: View {
    @Environment(AppState.self) private var state
    let repoID: UUID
    let path: String
    let commit: String
    @State private var preview: NoteRecoveryPreview?
    @State private var selected = Set<Int>()
    @State private var result: String?
    @State private var busy = false
    @State private var confirmWhole = false
    private var rendered: String {
        guard let draft = preview?.draft else { return "" }
        return draft.result(choices: Dictionary(uniqueKeysWithValues: draft.changes.map { ($0.id, selected.contains($0.id) ? ConflictMergeDraft.Choice.server : .phone) })) ?? ""
    }
    var body: some View {
        List {
            Text("Select changes to restore. Everything else keeps its current text. Nothing uploads until you sync.")
            if let preview {
                ForEach(preview.draft.changes) { block in
                    Section {
                        Text("Current").font(.caption)
                        Text(block.phone.joined(separator: "\n")).textSelection(.enabled)
                        Text("Historical").font(.caption)
                        Text(block.server.joined(separator: "\n")).textSelection(.enabled)
                        Toggle("Restore this change", isOn: Binding(get: { selected.contains(block.id) }, set: { if $0 { selected.insert(block.id) } else { selected.remove(block.id) } })).accessibilityIdentifier("recovery.change.\(block.id)")
                    }
                }
                Section("Result preview") { Text(rendered).textSelection(.enabled).accessibilityIdentifier("recovery.result") }
                Button("Restore selected changes") { restore(whole: false) }.disabled(selected.isEmpty || busy)
            }
            if let result { Text(result).textSelection(.enabled) }
            Button("Replace whole file…", role: .destructive) { confirmWhole = true }.disabled(busy)
            if busy { ProgressView() }
        }
        .navigationTitle("Compare and recover")
        .confirmationDialog("Replace the entire file? Newer checkboxes and text will be replaced. Its current bytes are backed up first.", isPresented: $confirmWhole) {
            Button("Replace whole file", role: .destructive) { restore(whole: true) }
        }
        .task {
            do { preview = try await state.serializedRepository(repoID: repoID).recoveryPreview(path: path, commit: commit) }
            catch { result = error.localizedDescription }
        }
    }
    private func restore(whole: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let repository = try state.serializedRepository(repoID: repoID)
                if whole { try await repository.restoreFile(path: path, from: commit) }
                else if let preview { try await repository.restoreSelection(preview: preview, selected: selected) }
                state.detectChanges(repoID: repoID)
                result = "Restored locally. Your previous file is protected. Sync when ready to upload."
                preview = nil; selected = []
            } catch { result = error.localizedDescription }
        }
    }
}
