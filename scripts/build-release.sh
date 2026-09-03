#!/bin/sh
set -eu

release_dir="${1:-release}"
mkdir -p "$release_dir"
release_abs="$(cd "$release_dir" && pwd)"
derived_dir="${TMPDIR:-/tmp}/VaultBridgeReleaseDerivedData"
project="ios/Sync.md.xcodeproj"
lockfile="$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

mkdir -p "$release_dir/Payload"
xcodebuild -project "$project" -scheme Sync.md -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_dir" CODE_SIGNING_ALLOWED=NO build

cp -R "$derived_dir/Build/Products/Release-iphoneos/Sync.md.app" "$release_dir/Payload/"
(cd "$release_dir" && zip -qry VaultBridge-unsigned.ipa Payload)
rm -rf "$release_dir/Payload"

if [ -d "$derived_dir/Build/Products/Release-iphoneos/Sync.md.app.dSYM" ]; then
  (cd "$derived_dir/Build/Products/Release-iphoneos" && zip -qry "$release_abs/VaultBridge.dSYM.zip" Sync.md.app.dSYM)
fi

ruby scripts/generate-sbom.rb "$lockfile" > "$release_dir/VaultBridge.spdx.json"
cp THIRD_PARTY_NOTICES.md "$release_dir/"
if [ -f "$release_dir/VaultBridge.dSYM.zip" ]; then
  (cd "$release_dir" && shasum -a 256 VaultBridge-unsigned.ipa VaultBridge.dSYM.zip VaultBridge.spdx.json THIRD_PARTY_NOTICES.md > SHA256SUMS)
else
  (cd "$release_dir" && shasum -a 256 VaultBridge-unsigned.ipa VaultBridge.spdx.json THIRD_PARTY_NOTICES.md > SHA256SUMS)
fi
