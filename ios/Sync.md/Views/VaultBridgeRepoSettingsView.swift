import SwiftUI

struct VaultBridgeRepoSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let repoID: UUID

    @State private var repoURL = ""
    @State private var branch = "main"
    @State private var authorName = ""
    @State private var authorEmail = ""
    @State private var authMethod: GitAuthMethod = .none
    @State private var username = ""
    @State private var secret = ""
    @State private var privateKey = ""
    @State private var publicKey = ""
    @State private var passphrase = ""
    @State private var autoSyncEnabled = true
    @State private var syncNotificationsEnabled = false
    @State private var notificationPermissionDenied = false
    @State private var saving = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Automation") {
                    Toggle("Sync when VaultBridge opens", isOn: $autoSyncEnabled)
                    Toggle("Notify after automatic sync", isOn: $syncNotificationsEnabled)
                        .disabled(!autoSyncEnabled)
                        .onChange(of: syncNotificationsEnabled) { _, enabled in
                            guard enabled else { return }
                            Task {
                                let allowed = await VaultBridgeLocalNotifications.requestAuthorization()
                                if !allowed {
                                    syncNotificationsEnabled = false
                                    notificationPermissionDenied = true
                                }
                            }
                        }
                    Text("Automatic sync commits local edits, rebases onto the remote branch, and pushes. Conflicts stop for review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Notifications are sent only when an automatic sync moves changes or needs your attention. Clean checks stay silent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Repository") {
                    TextField("Remote URL", text: $repoURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Branch", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Git Author") {
                    TextField("Name", text: $authorName)
                    TextField("Email", text: $authorEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("None / Public").tag(GitAuthMethod.none)
                        Text("HTTPS Token").tag(GitAuthMethod.httpsToken)
                        Text("SSH Key").tag(GitAuthMethod.sshKey)
                        if GitRemoteURL.parse(repoURL)?.isGitHub == true {
                            Text("GitHub Account").tag(GitAuthMethod.gitHubPAT)
                        }
                    }
                    if authMethod == .httpsToken {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Token or password", text: $secret)
                            .textInputAutocapitalization(.never)
                    } else if authMethod == .sshKey {
                        TextField("SSH username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextEditor(text: $privateKey)
                            .frame(minHeight: 120)
                            .font(.caption.monospaced())
                        SecureField("Passphrase (optional)", text: $passphrase)
                        DisclosureGroup("Public key (optional)") {
                            TextEditor(text: $publicKey)
                                .frame(minHeight: 70)
                                .font(.caption.monospaced())
                        }
                    }
                }

                Section {
                    NavigationLink("Debug Log") { DebugLogView() }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Timings, step names, and error text only. Never file names, vault contents, credentials, or paths.")
                }

                Section {
                    Button("Remove from VaultBridge", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                } footer: {
                    Text("Removing a vault forgets it in VaultBridge but does not delete an existing external folder.")
                }
            }
            .navigationTitle("Vault Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || repoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authorName.isEmpty || authorEmail.isEmpty)
                }
            }
            .task { load() }
            .confirmationDialog("Remove this vault from VaultBridge?", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    state.removeRepo(id: repoID)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Notifications Are Off", isPresented: $notificationPermissionDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow notifications for VaultBridge in iPhone Settings, then enable this option again.")
            }
        }
    }

    private func load() {
        guard let repo = state.repo(id: repoID) else { return }
        repoURL = repo.repoURL
        branch = repo.branch
        authorName = repo.authorName
        authorEmail = repo.authorEmail
        authMethod = repo.authMethod
        autoSyncEnabled = repo.autoSyncEnabled
        syncNotificationsEnabled = repo.syncNotificationsEnabled
        // Only surface the per-repo secrets that this repo's method actually
        // edits. A `.gitHubPAT` repo resolves to the account-wide OAuth/PAT
        // token; loading it into these fields would expose it if the user
        // flips the method picker, and re-save it as a per-repo credential.
        switch repo.authMethod {
        case .httpsToken:
            let credentials = state.remoteCredentials(for: repo)
            username = credentials.username
            secret = credentials.password
        case .sshKey:
            let credentials = state.remoteCredentials(for: repo)
            username = credentials.username
            privateKey = credentials.privateKey
            publicKey = credentials.publicKey
            passphrase = credentials.passphrase
        case .gitHubPAT, .none:
            username = repo.authUsername
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let credentials: GitRemoteCredentials
        switch authMethod {
        case .none: credentials = .none
        case .gitHubPAT: credentials = .gitHubPAT(secret)
        case .httpsToken: credentials = .httpsToken(username: username, password: secret)
        case .sshKey: credentials = .sshKey(username: username, privateKey: privateKey, publicKey: publicKey, passphrase: passphrase)
        }
        let saved = await state.saveRepoConfiguration(
            id: repoID,
            repoURL: repoURL,
            branch: branch,
            authorName: authorName,
            authorEmail: authorEmail,
            authMethod: authMethod,
            credentials: credentials
        )
        if saved {
            state.updateRepo(id: repoID) {
                $0.autoSyncEnabled = autoSyncEnabled
                $0.syncNotificationsEnabled = autoSyncEnabled && syncNotificationsEnabled
            }
            dismiss()
        }
    }
}
