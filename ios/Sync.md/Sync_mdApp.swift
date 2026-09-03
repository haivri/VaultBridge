import AppIntents
import SwiftUI

@MainActor
@main
struct VaultBridgeApp: App {
    @State private var appState = AppState()
    @State private var syncCoordinator = VaultBridgeSyncCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            SyncMDAppShortcutsProvider.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(syncCoordinator)
                .onOpenURL { url in
                    let handler = CallbackURLHandler(appState: appState)
                    if handler.canHandle(url) {
                        handler.handle(url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appState.validateClonedRepos()
            Task { await syncCoordinator.syncOnForeground(using: appState) }
        }
    }
}
