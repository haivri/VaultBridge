import SwiftUI

struct SafetyReviewView: View {
    @Environment(AppState.self) private var state
    @Environment(VaultBridgeSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    let repoID: UUID
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        List {
            Section {
                Text("These changes could remove recently received work or a large group of files. Previous saved versions are protected.")
                if let review = state.safetyReviewByRepo[repoID] {
                    ForEach(review.paths, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(path).font(.headline).textSelection(.enabled)
                            if let detail = review.details?.first(where: { $0.path == path }) {
                                Text(detail.reason).font(.caption)
                                Text(detail.removed.joined(separator: "\n")).textSelection(.enabled)
                            }
                            if path.lowercased().hasSuffix(".md") {
                                NavigationLink("Choose text to restore") { RecoveryNoteVersionsView(repoID: repoID, path: path) }
                            }
                        }
                    }
                    Text("Whole-file restoration replaces newer text and checkboxes. Current files are backed up first.").font(.caption)
                    Button("Restore whole files") { apply(review, approve: false) }
                    Button("Apply these exact changes", role: .destructive) { apply(review, approve: true) }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
                if busy { ProgressView() }
            }.disabled(busy)
        }
        .navigationTitle("Review changes")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done for now") { dismiss() } } }
    }
    private func apply(_ review: SyncSafetyReview, approve: Bool) {
        busy = true
        Task {
            do {
                let repository = try state.serializedRepository(repoID: repoID)
                try await repository.reviewSafetyChanges(approve: approve, review: review)
                state.safetyReviewByRepo.removeValue(forKey: repoID)
                await coordinator.sync(repoID: repoID, using: state)
                dismiss()
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}
