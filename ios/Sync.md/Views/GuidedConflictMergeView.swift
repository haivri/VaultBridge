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

    private func versionCard(_ lines: [String], side: ConflictMergeDraft.Choice, block: ConflictMergeDraft.Block) -> some View {
        let selected = choices[block.id] == side || choices[block.id] == .both
        return Button {
            choices[block.id] = ConflictMergeDraft.Choice.toggling(side, in: choices[block.id])
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(side.rawValue).font(.headline)
                    Spacer()
                    Label(selected ? "Keep" : "Tap to keep", systemImage: selected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                if lines.isEmpty {
                    Text("No lines here — keep this deletion").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            if let task = MarkdownTaskLine(line) {
                                Label(task.statusLabel, systemImage: task.isCompleted ? "checkmark.square" : "square")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(line.isEmpty ? " " : line).font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("merge.version.\(block.id).\(side == .phone ? "phone" : "server")")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint("Double tap to \(selected ? "remove" : "keep") this version. Selecting both keeps both copies.")
    }

    var body: some View {
        List {
            Section {
                Text("Combine edits in the original file. Changes made on only one side are included using the shared earlier version. Tap the version you want to keep for each overlapping change.")
                Text("Tap both versions to keep both, or tap a selected version to remove it. Your choices stay editable until you save.").font(.caption).foregroundStyle(.secondary)
            }
            if let draft {
                ForEach(Array(draft.changes.enumerated()), id: \.element.id) { index, block in
                    Section("Change \(index + 1) of \(draft.changes.count)") {
                        versionCard(block.phone, side: .phone, block: block)
                        versionCard(block.server, side: .server, block: block)
                        if choices[block.id] == .both {
                            Label("Both versions selected. Both copies will be kept; check for duplicate tasks or text in the preview.", systemImage: "doc.on.doc")
                                .font(.caption).foregroundStyle(.secondary)
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
                            Text(result).font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("merge.result")
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
