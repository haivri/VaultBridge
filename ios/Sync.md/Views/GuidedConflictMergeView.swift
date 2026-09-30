import SwiftUI

/// Choices remain editable in memory until the user explicitly saves the result.
struct GuidedConflictMergeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    let detail: ConflictFileDetail
    @State private var draft: ConflictMergeDraft?
    @State private var choices: [Int: ConflictMergeDraft.Choice] = [:]
    @State private var saving = false

    var body: some View {
        List {
            Section {
                Text("Keep the changes you want, one section at a time. Unchanged text stays. You can change any choice before saving.")
                Text("Both keeps the iPhone text followed by the server text; review it for duplicates.").font(.caption).foregroundStyle(.secondary)
            }
            if let draft {
                ForEach(Array(draft.changes.enumerated()), id: \.element.id) { index, block in
                    Section("Change \(index + 1) of \(draft.changes.count)") {
                        Text("iPhone").font(.headline)
                        Text(block.phone.isEmpty ? "No lines here" : block.phone.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled)
                        Text("Server").font(.headline)
                        Text(block.server.isEmpty ? "No lines here" : block.server.joined(separator: "\n")).font(.callout.monospaced()).textSelection(.enabled)
                        ForEach(ConflictMergeDraft.Choice.allCases, id: \.self) { choice in
                            Button {
                                choices[block.id] = choice
                            } label: {
                                Label("Keep \(choice.rawValue)", systemImage: choices[block.id] == choice ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
                Section {
                    Text("\(choices.count) of \(draft.changes.count) changes chosen")
                    if let result = draft.result(choices: choices) {
                        DisclosureGroup("Preview complete result") {
                            Text(result).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        Button("Save combined result") {
                            saving = true
                            Task {
                                await state.resolveConflictWithContent(repoID: repoID, path: detail.lookupPath, content: Data(result.utf8), expected: detail)
                                saving = false
                                if state.conflictSessionByRepo[repoID]?.unmergedPaths.contains(detail.lookupPath) == false { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("Choose a version for every change to enable saving.").foregroundStyle(.secondary)
                    }
                }
            } else { ProgressView("Finding changed sections…") }
        }
        .disabled(saving || state.isSyncing)
        .navigationTitle("Choose each change")
        .task {
            guard let phone = detail.ours?.content.flatMap({ String(data: $0, encoding: .utf8) }),
                  let server = detail.theirs?.content.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            let result = await Task.detached(priority: .userInitiated) { ConflictMergeDraft(phone: phone, server: server) }.value
            guard !Task.isCancelled else { return }
            draft = result
        }
    }
}
