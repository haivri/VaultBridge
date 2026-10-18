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
                Text("Combine edits in the original file. Changes made on only one side are included using the shared earlier version. If both sides changed the same text, choose what to keep below.")
                Text("Both keeps both alternatives inside this file; review them for duplicates. Saving does not create a second file.").font(.caption).foregroundStyle(.secondary)
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
                    if draft.changes.isEmpty {
                        Label("The edits fit together in one file", systemImage: "checkmark.document")
                    } else {
                        Text("\(choices.count) of \(draft.changes.count) overlapping changes chosen")
                    }
                    if let result = draft.result(choices: choices) {
                        DisclosureGroup("Preview complete result") {
                            Text(result).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        Button("Save merged file") {
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
        .navigationTitle("Merge into one file")
        .task {
            guard let phone = detail.ours?.content.flatMap({ String(data: $0, encoding: .utf8) }),
                  let server = detail.theirs?.content.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            let ancestor = detail.ancestor?.content.flatMap { String(data: $0, encoding: .utf8) }
            let result = await Task.detached(priority: .userInitiated) {
                ConflictMergeDraft(phone: phone, server: server, ancestor: ancestor)
            }.value
            guard !Task.isCancelled else { return }
            draft = result
        }
    }
}
