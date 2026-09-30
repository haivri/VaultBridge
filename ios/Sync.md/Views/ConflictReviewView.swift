import SwiftUI

/// The normal human-choice flow. Git tools remain optional.
struct ConflictReviewView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultBridgeSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    @State private var details: [ConflictFileDetail] = []
    @State private var loading = true
    @State private var busy = false
    @State private var unreadable = false
    @State private var pendingChoice: ConflictFileDetail?
    @State private var pendingStrategy: ConflictResolutionStrategy = .ours

    var body: some View {
        List {
            Section {
                Label("Both originals are protected", systemImage: "checkmark.shield")
                Text("Review the highlighted differences, then choose a result. Whole-file choices ask you to confirm before saving. Nothing uploads until you finish.")
                    .foregroundStyle(.secondary)
            }
            if loading { ProgressView("Finding files that need your choice") }
            ForEach(Array(details.enumerated()), id: \.element.lookupPath) { index, detail in
                Section {
                    Text(detail.lookupPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if detail.lookupPath.hasPrefix(".obsidian/") {
                        Text("These are Obsidian settings. Choose the settings you want active; the server version is not necessarily newer.")
                    }
                    if let differences = settingsDifferences(detail), !differences.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Settings that differ").font(.headline)
                            ForEach(differences, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                        }
                    }
                    ConflictComparisonView(detail: detail)
                    version(detail.ours, title: "Full iPhone original")
                    version(detail.theirs, title: "Full server original")
                    if !detail.isRenameRename,
                       detail.ours?.isBinary == false, detail.theirs?.isBinary == false,
                       let phone = detail.ours?.content, let server = detail.theirs?.content,
                       String(data: phone, encoding: .utf8) != nil, String(data: server, encoding: .utf8) != nil {
                        NavigationLink("Choose changes one by one") { GuidedConflictMergeView(repoID: repoID, detail: detail) }
                    }
                    if detail.isRenameRename {
                        NavigationLink("Choose filename and combine edits", value: ConflictEditorDestination(repoID: repoID, path: detail.lookupPath))
                    } else {
                        Button(detail.ours == nil ? "Keep the iPhone deletion" : "Use this iPhone’s version") { previewChoice(detail, .ours) }
                        Button(detail.theirs == nil ? "Keep the server deletion" : "Use server version") { previewChoice(detail, .theirs) }
                        if detail.ours?.isBinary != true && detail.theirs?.isBinary != true {
                            NavigationLink("Edit combined text manually", value: ConflictEditorDestination(repoID: repoID, path: detail.lookupPath))
                        }
                        if detail.ours?.content != nil && detail.theirs?.content != nil && !detail.lookupPath.hasPrefix(".obsidian/") {
                            Button("Keep both copies") {
                                busy = true
                                Task {
                                    let name = URL(fileURLWithPath: detail.theirs!.path)
                                    let relative = (detail.theirs!.path as NSString).deletingPathExtension + " (Server copy \(UUID().uuidString.prefix(8)))" + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension)
                                    _ = await state.resolveConflictKeepingBoth(repoID: repoID, detail: detail, serverCopyPath: relative)
                                    await reload(); busy = false
                                }
                            }
                        }
                    }
                } header: {
                    Text("File \(index + 1) of \(details.count) · \(detail.lookupPath.hasPrefix(".obsidian/") ? "Obsidian settings" : (detail.lookupPath as NSString).lastPathComponent)")
                }
                .disabled(busy || state.isSyncing)
            }
            if unreadable { Text("A file preview could not be loaded. Your choices are preserved. Try opening this review again.") }
            if !loading && !unreadable && details.isEmpty {
                Section {
                    Label("Your choices are saved", systemImage: "checkmark.circle")
                    if state.conflictSessionByRepo[repoID]?.kind == .merge {
                        Button("Save locally and review recovery options") {
                            busy = true
                            Task {
                                await state.completeMerge(repoID: repoID)
                                await reload(); busy = false
                            }
                        }
                        .disabled(busy || state.isSyncing)
                        Text("Saves the merge on this iPhone without uploading. You can then recover a file before syncing.").font(.caption)
                    } else if state.conflictSessionByRepo[repoID]?.isActive != true {
                        NavigationLink("Recover previous work") { FileRecoveryView(repoID: repoID) }
                            .accessibilityIdentifier("merge.recover")
                    }
                    Button("Save and finish syncing") {
                        busy = true
                        Task {
                            await coordinator.sync(repoID: repoID, using: state)
                            busy = false
                            if coordinator.status(for: repoID).phase == .complete { dismiss() }
                            else { await reload() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || state.isSyncing)
                    if coordinator.status(for: repoID).message != "Ready" {
                        Text(coordinator.status(for: repoID).message).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Review your files")
        .confirmationDialog("Replace the entire file?", isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } })) {
            Button(pendingStrategy == .ours ? "Save iPhone version" : "Save server version", role: .destructive) {
                if let detail = pendingChoice { choose(detail, pendingStrategy) }
                pendingChoice = nil
            }
            Button("Go back to differences") { pendingChoice = nil }
        } message: {
            Text("This keeps the selected version of the whole file, including its deletions. Unique edits from the other version will not appear in the result. Choose changes one by one to keep edits from both sides. Originals remain in saved checkpoints.")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done for now") { dismiss() } } }
        .navigationDestination(for: ConflictEditorDestination.self) { destination in
            ConflictEditorView(repoID: destination.repoID, path: destination.path)
        }
        .task { await reload() }
        .onChange(of: state.conflictSessionByRepo[repoID]) { Task { await reload() } }
    }

    @ViewBuilder private func version(_ side: ConflictFileSide?, title: String) -> some View {
        DisclosureGroup(title) {
            if let side {
                if side.isBinary { Label("Attachment", systemImage: "doc") }
                else if let content = side.content, let text = String(data: content, encoding: .utf8) {
                    let formatted = (try? JSONSerialization.jsonObject(with: content)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) }.flatMap { String(data: $0, encoding: .utf8) } ?? text
                    Text(formatted).font(.body.monospaced()).textSelection(.enabled)
                } else { Text("Preview unavailable. The original is protected.") }
            } else { Text("Deleted on this side").foregroundStyle(.secondary) }
        }
    }
    private func settingsDifferences(_ detail: ConflictFileDetail) -> [String]? {
        guard detail.lookupPath.hasPrefix(".obsidian/"),
              let ours = detail.ours?.content, let theirs = detail.theirs?.content,
              let phone = try? JSONSerialization.jsonObject(with: ours) as? [String: Any],
              let server = try? JSONSerialization.jsonObject(with: theirs) as? [String: Any] else { return nil }
        func value(_ object: Any?) -> String {
            guard let object else { return "Not set" }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) { return text }
            return String(describing: object)
        }
        return Set(phone.keys).union(server.keys).sorted().compactMap { key in
            let a = value(phone[key]), b = value(server[key])
            return a == b ? nil : "\(key)\nThis iPhone: \(a)\nServer: \(b)"
        }
    }
    private func previewChoice(_ detail: ConflictFileDetail, _ strategy: ConflictResolutionStrategy) {
        pendingStrategy = strategy
        pendingChoice = detail
    }
    private func choose(_ detail: ConflictFileDetail, _ strategy: ConflictResolutionStrategy) {
        busy = true
        Task {
            await state.resolveConflictFile(repoID: repoID, path: detail.lookupPath, strategy: strategy, expected: detail)
            await reload(); busy = false
        }
    }
    private func reload() async {
        await state.loadConflictSession(repoID: repoID)
        let paths = state.conflictSessionByRepo[repoID]?.unmergedPaths ?? []
        var result: [ConflictFileDetail] = []
        for path in paths {
            if let detail = await state.loadConflictDetail(repoID: repoID, path: path) { result.append(detail) }
        }
        details = result; unreadable = result.count != paths.count; loading = false
    }
}
