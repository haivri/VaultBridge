import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VaultBridgeDashboardView()
            .alert(
                state.pendingSSHHostKeyTrustRequest?.title ?? "Trust SSH Host?",
                isPresented: Binding(
                    get: { state.pendingSSHHostKeyTrustRequest != nil },
                    set: { _ in }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    state.cancelPendingSSHHostKeyTrust()
                }
                Button(state.pendingSSHHostKeyTrustRequest?.confirmButtonTitle ?? "Trust Host") {
                    Task { await state.trustPendingSSHHostKeyAndRetry() }
                }
            } message: {
                Text(state.pendingSSHHostKeyTrustRequest?.message ?? "")
            }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(VaultBridgeSyncCoordinator())
}
