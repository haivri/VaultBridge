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
                    ForEach(review.paths, id: \.self) { Text($0).font(.body).textSelection(.enabled) }
                    Button("Restore protected files") { apply(review, approve: false) }
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
