# Native VaultBridge contract

- Preserve `ios/GITSYNCMD_LICENSE` and the upstream provenance in `README.md`.
- Never add credentials, tokens, private keys, vault contents, or local repository
  paths to source control, logs, analytics, or the sync journal.
- Automatic workflows must be non-destructive: no force push, reset, checkout
  discard, file deletion, or conflict auto-resolution.
- Keep local commit distinct from network push in the manual UI.
- Maintain backward-compatible decoding for persisted repository configuration.
- Validate changes with a native build, focused tests, a disposable Git remote,
  and an iPhone device build before replacing the shipped Flutter application.
