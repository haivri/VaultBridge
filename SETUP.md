# Setting up VaultBridge

VaultBridge keeps a normal Git repository on the iPhone. Obsidian edits the
working files in that folder; VaultBridge saves those edits as local commits,
combines server changes, uploads, and verifies the result.

Before beginning, make a separate backup of an important existing vault. Git is
useful recovery history, but it is not a substitute for an independent backup.

## 1. Install the public release

You need a Mac with Xcode 26 or newer, an iPhone running iOS 17 or newer, and an
Apple ID that Xcode can use for development signing.

```sh
git clone https://github.com/haivri/VaultBridge.git
cd VaultBridge
open ios/Sync.md.xcodeproj
```

In Xcode:

1. Select the **Sync.md** project and the **Sync.md** app target.
2. Open **Signing & Capabilities**.
3. Choose your Apple development team.
4. Replace `org.vaultbridge.VaultBridge` with a bundle identifier you control.
5. Select your connected iPhone and press **Run**.

If iOS asks you to trust the development certificate or enable Developer Mode,
follow the prompt and run again. Personal signing values belong only in your
local Xcode settings; do not commit them.

The `VaultBridge-unsigned.ipa` attached to a GitHub release is intentionally
unsigned. It is provided for people who already have an IPA-signing workflow;
it is not directly installable. See [BUILDING.md](BUILDING.md) for command-line
build and signing details.

## 2. Prepare the vault repository

VaultBridge works with ordinary Git remotes over HTTPS or SSH. GitHub,
Forgejo/Gitea, GitLab, Bitbucket, and self-hosted servers are supported.

For the smoothest first clone:

- Give the remote a default branch such as `main` and at least one commit.
- Commit the vault files you want on the phone, including `.obsidian` settings
  if you want those settings synchronized.
- Keep secrets out of the vault repository, especially if the remote is public.
- If the repository uses Git LFS, confirm that LFS is enabled on the server and
  that all referenced LFS objects have been uploaded before cloning the phone.

### Authentication choices

| Remote | VaultBridge choice | What to provide |
| --- | --- | --- |
| Public, read-only | **No Authentication** | Nothing; uploading will not work without write access. |
| GitHub HTTPS | **GitHub Account** or HTTPS token | A fine-grained token with repository **Contents: Read and write**, or a classic token with `repo` for private repositories. |
| Forgejo/Gitea or other HTTPS | **HTTPS Token** | Your username and an access token/password with repository read/write permission. Forgejo tokens can use `write:repository`. |
| SSH | **SSH Private Key** | SSH username (usually `git`), an OpenSSH private key, and its optional passphrase. Verify the displayed host-key fingerprint before trusting it. |

Credentials are stored in the iOS Keychain. Do not put a token or password in
the repository URL. GitHub documents its current token choices in
[Managing personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
Forgejo documents its token scopes in its
[authentication guide](https://forgejo.org/docs/latest/user/).

Public VaultBridge builds do not include a hosted GitHub OAuth service. Use a
personal access token or SSH key unless you operate and configure your own OAuth
exchange.

## 3. Add the repository on the iPhone

On first launch, choose **Personal Access Token** for GitHub or **Continue
without GitHub** for a self-hosted server, SSH remote, public remote, or local
repository. Then choose **Add Repository**.

### Clone a remote repository

1. Pick a GitHub repository or choose **Enter URL Manually**.
2. Enter the remote URL and branch, normally `main`.
3. Enter the author name and email that should appear on phone commits.
4. Select an authentication method and enter its credentials.
5. Under **Clone To**, keep the default on-device location or choose a folder
   that both VaultBridge and Obsidian can access.
6. Tap **Add & Clone Repository** and leave the app open for the initial clone.

The default location appears in Files as:

```text
On My iPhone › GitSync.md › <vault-name>
```

Choose an **On My iPhone** location when you want the vault stored locally
rather than in iCloud Drive.

### Use an existing repository on the phone

If the vault folder already contains a `.git` directory:

1. Choose **Open Existing Repository**.
2. Select the repository root—the folder containing `.git`, not `.git` itself.
3. Enter the commit author name and email.
4. Tap **Add Repository**.
5. Open the repository settings and configure its remote authentication if it
   is not already usable.

VaultBridge bookmarks the selected folder; it does not copy or replace it.

## 4. Open the same folder in Obsidian

In Obsidian, open the vault switcher, choose **Open folder as vault**, and select
the exact folder cloned or opened above. The vault root is the folder containing
the notes and `.obsidian` directory.

If Obsidian cannot select VaultBridge's default folder on your iOS version,
create or select the vault location from Obsidian first, make that folder a Git
repository, and use VaultBridge's **Open Existing Repository** path. Both apps
must ultimately reference the same on-device folder.

Do not enable two independent Git sync tools against the same phone folder at
the same time. Obsidian Sync can also create simultaneous writes; let it finish
before running VaultBridge if you deliberately use both systems.

## 5. Run the first sync

Tap **Sync Now** on the vault screen. A normal run performs these steps:

1. Waits briefly for active note writes to settle.
2. Creates and verifies a local checkpoint on the iPhone.
3. Checks the server.
4. Downloads or safely combines server changes.
5. Uploads the phone commits.
6. Verifies the final phone and server commit IDs.

An **Up to date** result means the checked phone and server revisions agree. A
local checkpoint is safe on the phone even before upload; the interface shows
its short commit hash and age. If both sides changed the same lines, VaultBridge
stops at **Resolve Conflicts** and asks which content to keep.

The expert drawer exposes the individual Git operations and recovery tools.
Those are not required for routine use.

## 6. Git LFS

VaultBridge understands standard Git LFS pointer files and the Git LFS batch
API. It uploads missing objects before moving the Git branch, verifies object
size and SHA-256, streams large transfers through files instead of memory, and
restores pointer stubs during sync even when Git itself is already up to date.

VaultBridge honors existing `.gitattributes` rules. It also automatically uses
LFS for supported binary categories such as PDFs, audio/video, archives, and
design files, and for otherwise large binary files. A typical explicit rule is:

```gitattributes
*.pdf filter=lfs diff=lfs merge=lfs -text
*.mov filter=lfs diff=lfs merge=lfs -text
Attachments/** filter=lfs diff=lfs merge=lfs -text
```

Adding a rule does not rewrite old Git history. Migrate existing large blobs on
a desktop with Git LFS before expecting historical revisions to use LFS.

For Forgejo, the server administrator should verify LFS storage, quotas, and
timeouts. Forgejo's current installation documentation notes that LFS is stored
under its data directory by default and describes settings for large transfers:
[Forgejo installation and LFS](https://forgejo.org/docs/latest/admin/installation/binary/).

If an attachment opens as text beginning with `version
https://git-lfs.github.com/spec/v1`, run **Sync Now**. In **Git Tools &
Recovery**, **Repair Missing Attachment Backups** checks every current LFS
object on the server and uploads only missing payloads; it does not change files
or Git history.

## Troubleshooting

- **Server not checked yet:** Run **Sync Now** with the phone online. If it
  remains unchanged, verify the remote URL, branch, credentials, and SSH host
  trust in repository settings.
- **Some notes were still being written:** Return to Obsidian, let the save or
  attachment move finish, wait a moment, and run **Sync Now** again. VaultBridge
  refuses to overwrite a file while another app is changing it.
- **Authentication failed:** For HTTPS, use a token—not the account password—
  and confirm repository write permission. For SSH, confirm the username, key,
  passphrase, and server fingerprint.
- **LFS download/upload failed:** Confirm server-side LFS is enabled, the token
  can access the repository, quotas are not exhausted, and large-transfer
  timeouts are sufficient. HTTPS token authentication can be simpler than SSH
  on servers that do not implement `git-lfs-authenticate`.
- **Phone and server histories diverged:** Use **Sync Now** to make a normal
  merge. Rebase and emergency replacement are expert/recovery actions; read the
  on-screen consequences before using them.

For diagnostics, open the repository's Git tools and use the debug log. Logs and
sync journals intentionally omit filenames, document contents, repository URLs,
and credentials.
