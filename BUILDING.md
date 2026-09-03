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
