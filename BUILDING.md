# Building and signing

1. Install Xcode 26 or newer.
2. Open `ios/Sync.md.xcodeproj` and allow Swift Package Manager to resolve the
   pinned dependencies.
3. Select the `Sync.md` scheme and an iPhone.
4. Choose your Apple development team and set a bundle identifier you control.

Command-line build without signing:

```sh
xcodebuild \
  -project ios/Sync.md.xcodeproj \
  -scheme Sync.md \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

To upgrade an existing private installation in place, pass its existing bundle
identifier and development team as command-line build-setting overrides. Do not
commit those personal values.

The release IPA is intentionally unsigned. Unzip it, sign `Payload/Sync.md.app`
with your own identity and provisioning profile, then recreate the ZIP/IPA.

## Optional services

- GitHub OAuth is disabled unless `OAUTH_SERVER_BASE_URL` is configured to a
  trusted HTTPS exchange operated by the builder. PAT authentication needs no
  VaultBridge service.
- Analytics is disabled. Test builds can explicitly set
  `ONBOARDING_ANALYTICS_ENABLED=1` and provide their own endpoint.
- The optional Assist relay has no public default endpoint.

## 1.1.2 recovery validation (2026-10-11)

The signed simulator suite passed all 209 tests, including a disposable local
Git remote/clone with unsaved working-copy edits, unavailable-bookmark handling,
and occupied-destination preservation. An initial unsigned simulator run failed
keychain-dependent tests; rerunning with simulator ad hoc signing passed the
entire suite. The Release iPhone build passed and was installed in place with
the existing valid ad hoc profile. Launch and continuing process presence were
verified. A read-only metadata check confirmed the existing repository identity
and folder bookmark were retained and its cleared clone status was recovered.
No user-vault clone, replacement, reset, or manual metadata injection was used.

## 1.1.3 merge validation (2026-10-18)

The signed simulator suite passed all 214 unit/integration tests and all three
UI tests. A disposable bare remote, independent phone/server clones, and a fresh
verification clone exercised a daily-note content conflict, single-file merge,
normal push, new journal preservation, and a moved note. Regression cases cover
adjacent inserts/replacements, overlapping edits, deletions, reopened checkboxes,
identical edits, repeated lines, Unicode, and final newlines. UI tests verified
editable merge choices, saving, and recovery without an upload.

The Release iPhone build passed, its signature was verified, and version 1.1.3
was installed in place with the existing app identity and valid ad hoc profile.
The live vault was not used as a test fixture.

## 1.1.4 merge preference validation (2026-10-18)

The signed simulator suite passed all 216 unit/integration tests and all four
UI tests. Coverage includes the disposable-remote single-file merge round trip,
legacy/unknown preference defaults, and preference persistence across concurrent
sync metadata updates. The UI test verified the default single-file action,
changing and reopening the saved preference, and explicitly creating separate
files from the preferred action. Existing merge and recovery UI tests passed.

The Release iPhone build passed and its signature was verified with the existing
valid ad hoc profile. Version 1.1.4 was installed in place using the existing app
identity. The live vault was not used as a test fixture.

## 1.2.0 text protection and recovery validation (2026-11-22)

The native unit/integration suite passed all 219 tests. Final focused validation
passed the three affected persistence, approval, and selective-recovery tests and
all five UI tests. The synthetic recovery screen restored a missing timestamp
while retaining a newer checked box. Coverage includes legacy recovery manifests,
unrelated integrations, restart, stale decisions, repeated lines, Unicode, CRLF,
local recovery copies, and saving without an upload. One simulator run hit a
Busy app-launch service; restarting only that test simulator resolved it. The
new toggle UI test targets the switch control explicitly.

The Release iPhone build passed with the existing private app identity supplied
only as a build override. The existing ad hoc profile remains valid. No real
vault was used as a test fixture, and no vault was replaced, reset, or recloned.
