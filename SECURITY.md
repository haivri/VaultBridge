# Security policy

Please report vulnerabilities privately through GitHub's security-advisory
feature for `haivri/VaultBridge`. Do not include real tokens, SSH keys, vault
contents, or private remote URLs in a report. Supported security fixes target
the latest release.

VaultBridge stores credentials in the iOS Keychain. Its sync journal contains
phase metadata only. Public builds send no analytics by default.
