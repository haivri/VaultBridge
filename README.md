# VaultBridge

VaultBridge is a native SwiftUI iPhone app that safely synchronizes folders and
Obsidian vaults with Git. Its primary interface describes outcomes in ordinary
language while keeping normal Git controls available to experienced users.

## Get started

The public release contains source code and an **unsigned** IPA. The IPA cannot
be installed unchanged; build the app with your own Apple development team or
sign it with your own provisioning profile.

1. Follow [SETUP.md](SETUP.md) to install the app on an iPhone.
2. Prepare a GitHub, Forgejo/Gitea, GitLab, or other reachable Git repository.
3. In VaultBridge, add and clone that repository—or open an existing Git
   repository already stored on the phone.
4. Point Obsidian at the same folder.
5. Tap **Sync Now**. VaultBridge creates a local checkpoint before contacting
   the server and shows the phone and server commit IDs when it finishes.

The setup guide includes HTTPS tokens, SSH keys, on-device vault placement,
Git LFS, first-sync behavior, and common troubleshooting. For build-only and
command-line signing details, see [BUILDING.md](BUILDING.md).

## Safety model

The vault screen has one button, **Sync Now**. It saves this phone, checks the
server, brings server changes in (a fast-forward when only the server moved, a
merge commit when both sides moved), uploads, and verifies. It changes only
when a person must choose: **Resolve Conflicts**.

- A merge never rewrites phone commits, so the commit ID shown as proof of a
  save stays valid. Rebase remains an explicit "Advanced" tool in the drawer.
- Uploading checks the server first. A server that moved is reported in plain
  language and combined by the next sync instead of looping on a rejected push.
- VaultBridge never force-pushes.
- Combine and Emergency Replace contact the server before touching any phone
  file, so an offline device cannot strand edits in a stash. Edits that must be
  set aside are recorded as **sheltered edits**, shown on the vault screen, and
  put back automatically by the next sync or when a combine finishes.
- Replacing phone files from the server requires `REPLACE` and first preserves
  HEAD in `refs/vaultbridge/recovery/…` plus dirty and untracked files in a stash.
  Restoring that backup protects the current files the same way first, so it is
  always reversible.
- Every conflict requires an explicit choice. Revert lives in the expert drawer.

Automatic sync performs checkpoint → fetch → classify → merge → normal push.
It stops for conflicts, credentials, host trust, or recovery approval. Runs are
journaled without filenames, URLs, credentials, or document contents. Work that
leaves the foreground holds a background assertion whose expiration cancels the
work cleanly and, on iOS 26, may continue as a system continued-processing task.

## Requirements

- Xcode 26 or newer
- iOS 17 or newer
- A Git remote reachable over HTTPS or SSH

Public builds have no analytics endpoint and no hosted OAuth service. A Git
personal access token works without any external VaultBridge service.

## Origin and license

VaultBridge includes work originally imported from
[CodyBontecou/GitSync.md](https://github.com/CodyBontecou/GitSync.md) commit
`5322cb334cc543071ee941c0295f6afc37560ca0`. Its original MIT notice is preserved
at `ios/GITSYNCMD_LICENSE`.

VaultBridge is MIT licensed. Dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
