# Changelog

## 1.1.4

- Add a per-vault Conflict Review preference, defaulting to merging into the original file.
- Offer two separate files first only when selected; every conflict still requires review and an explicit save.
- Preserve the preference across upgrades and concurrent sync metadata updates.

## 1.1.3

- Merge edits into one original file using the shared ancestor, preserving independent additions, task updates, and journal entries.
- Require a choice for overlapping edits and explicit saving of the preview.
- Separate the two-file copy action from the single-file merge flow.

## 1.1.2

- Preserve saved clone state when device protection or a file provider hides the repository temporarily.
- Reconnect an existing local Git repository when old versions cleared its clone metadata.
- Refuse to move or replace an occupied destination through the clone action.
- Show reconnect/download wording instead of declaring an existing vault un-cloned.

## 1.1.1

- Show line-numbered iPhone/server differences with unchanged text collapsed.
- Combine conflicting text by choosing each changed section, with editable choices and a complete result preview.
- Confirm whole-file replacements and offer local-only merge completion before recovery.
- Recover either original directly from a recent merge checkpoint.

## 1.0.0

- Native SwiftUI-only release.
- Plain-language, state-driven synchronization actions.
- Local checkpoint proof and separate upload action.
- Explicit rebase and merge choices with guided conflict wording.
- Guarded server replacement with recoverable Git ref and stash.
- Path-scoped Git/LFS staging for faster checkpoints.
- Durable sync phases and iOS background continuation.
- No analytics or hosted OAuth endpoint by default.
