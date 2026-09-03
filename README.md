# VaultBridge

VaultBridge is a native SwiftUI iPhone app that safely synchronizes folders and
Obsidian vaults with Git. Its primary interface describes outcomes in ordinary
language while keeping normal Git controls available to experienced users.

## Safety model

- **Save on This iPhone** creates a local Git checkpoint and never uploads it.
- **Get Server Updates** fast-forwards only when it is safe.
- Rebase and merge are explicit alternatives when histories diverge.
- Merge completion and upload are separate actions.
- VaultBridge never force-pushes.
- Replacing phone files from the server requires `REPLACE` and first preserves
  HEAD in `refs/vaultbridge/recovery/…` plus dirty and untracked files in a stash.
- Every conflict requires an explicit choice.

Automatic sync performs checkpoint → fetch → classify → rebase → normal push.
It stops for conflicts, credentials, host trust, or recovery approval. Runs are
journaled without filenames, URLs, credentials, or document contents and resume
safely after foreground interruption.

## Requirements

- Xcode 26 or newer
- iOS 17 or newer
- A Git remote reachable over HTTPS or SSH

See [BUILDING.md](BUILDING.md) for build and signing instructions. Public builds
have no analytics endpoint and no hosted OAuth service. A Git personal access
token works without any external VaultBridge service.

## Origin and license

VaultBridge includes work originally imported from
[CodyBontecou/GitSync.md](https://github.com/CodyBontecou/GitSync.md) commit
`5322cb334cc543071ee941c0295f6afc37560ca0`. Its original MIT notice is preserved
at `ios/GITSYNCMD_LICENSE`.

VaultBridge is MIT licensed. Dependencies retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
