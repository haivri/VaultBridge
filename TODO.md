# VaultBridge TODO

## Manual Git tools: plain-language explanations with Git button labels

Requested after reviewing Vault Git Sync 1.3.0: keep the approachable explanation of
what happens and where, but use the familiar Git operation on the action button.
The user specifically prefers this combination over replacing Git terminology entirely.

Reference: `../plugins/vault-git-sync/main.js`, commit `5864816`, especially `ACTIONS`
and `renderTools`. Adapt the interface pattern to native SwiftUI; do not copy desktop
Git execution code or change existing operation semantics as part of this UI pass.

- [ ] Apply the pattern to `ios/Sync.md/Views/VaultView.swift` (`gitToolsSection` and
  `gitToolButton`) and `ios/Sync.md/Views/GitControlSheet.swift`.
- [ ] Keep the explanatory title and subtitle adjacent to a distinct, concise action:

  | Explanation | Button |
  | --- | --- |
  | Save on this iPhone only — creates a restore point here and uploads nothing. | Commit |
  | Bring newer server changes here — requires saved local files and no competing history; never uploads. | Pull |
  | Combine iPhone and server changes here — saves local work, combines histories, and stops for unresolved conflicts. | Merge |
  | Upload saved work — checks the server and sends existing local commits. | Push |
  | Finish a resolved merge — creates the merge commit here; uploading remains separate. | Finish merge |
  | Put unuploaded iPhone work after server work — changes local commit IDs. | Rebase |
  | Save, combine, and upload using the established sync workflow. | Sync now |

- [ ] Retain the existing force-save, restore-backup, and emergency server-replacement
  actions as separate operations with explicit explanations and confirmations.
  Do not label server replacement “Force merge”: conflict-preference merging and
  replacing a working copy are different operations. Any new force-merge feature
  requires its own scoped implementation and recovery tests.
- [ ] Show progress and a persistent plain-language outcome, including whether work
  was saved locally, downloaded, or uploaded. Disable competing actions while busy.
- [ ] Show the next useful step after a blocked action or failure, preserving conflict
  and recovery information. Keep commit separate from push throughout the flow.
- [ ] Check small iPhone widths, Dynamic Type, VoiceOver labels, and button alignment.
- [ ] Validate existing operation routing with focused tests, a native build, and an
  iPhone device build before shipping. This TODO does not change sync behavior.
