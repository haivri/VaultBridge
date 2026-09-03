# Contributing

Open an issue before large behavioral changes. Pull requests must preserve the
safety contract in `AGENTS.md`, add focused tests, and pass a native simulator
build. Never add real repository URLs, filesystem paths, tokens, vault content,
signing identities, or provisioning profiles to fixtures or logs.

Manual Git operations must keep checkpoint, reconcile, and upload distinct.
Automatic operations must remain non-destructive and must never force-push or
resolve conflicts without the user.
