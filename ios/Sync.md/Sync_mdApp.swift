import AppIntents
import SwiftUI
import UserNotifications

@MainActor
@main
struct VaultBridgeApp: App {
    @State private var appState = AppState()
    @State private var syncCoordinator = VaultBridgeSyncCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SyncSafetyUITest") {
            let persistence = FileManager.default.temporaryDirectory.appendingPathComponent("ui-fixture-\(UUID()).json")
            _appState = State(initialValue: AppState(reposFileURL: persistence, loadPersistedState: false))
        }
        #endif
        UNUserNotificationCenter.current().delegate = VaultBridgeNotificationRouter.shared
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            SyncMDAppShortcutsProvider.updateAppShortcutParameters()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(syncCoordinator)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-SyncSafetyUITest") && appState.repos.isEmpty {
                        do { try await SyncSafetyUIFixture.prepare(appState) }
                        catch { appState.showError(message: "Synthetic review setup failed: " + error.localizedDescription) }
                    }
                    #endif
                }
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
