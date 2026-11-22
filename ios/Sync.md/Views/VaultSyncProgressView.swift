import SwiftUI

/// Shared by the vault and the review sheet, so progress is visible at the
/// point where syncing was started, rather than hidden behind a presentation.
struct VaultSyncProgressView: View {
    let status: VaultBridgeSyncStatus
    let identifier: String

    var body: some View {
        if let stage = status.phase.stage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Step \(stage.number) of 5 · \(stage.title)")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier(identifier + ".stage")
                }
                ProgressView(value: Double(stage.number - 1), total: 5)
                    .accessibilityLabel("Sync stages completed")
                    .accessibilityValue("\(stage.number - 1) of 5; \(stage.title) in progress")
                    .accessibilityIdentifier(identifier)
                Text(status.message).font(.subheadline).foregroundStyle(.secondary)
                Text(stage.number == 5 ? "Final step: checking files and attachment backups before confirming completion." : "Progress shows sync stages, not time remaining. Stages may repeat if files change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
