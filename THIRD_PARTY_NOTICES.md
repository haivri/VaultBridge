# Third-party notices

VaultBridge's MIT license applies only to VaultBridge-authored work. The
following components retain their own licenses and copyright notices.

| Component | Pinned version | License |
| --- | --- | --- |
| GitSync.md foundation | commit `5322cb3` | MIT; full notice in `ios/GITSYNCMD_LICENSE` |
| libgit2 | bundled XCFramework | GPL-2.0-only with linking exception; [upstream notice](https://github.com/libgit2/libgit2/blob/main/COPYING) |
| BigInt | 5.7.0 | MIT |
| Citadel | 0.12.1 | MIT |
| Notelet | commit `0298690` | MIT |
| swift-asn1 | 1.7.0 | Apache-2.0 |
| swift-atomics | 1.3.0 | Apache-2.0 |
| swift-collections | 1.5.0 | Apache-2.0 |
| swift-crypto | 3.15.1 | Apache-2.0 |
| swift-log | 1.12.0 | Apache-2.0 |
| swift-nio | 2.99.0 | Apache-2.0 |
| swift-nio-ssh | 0.3.6 | Apache-2.0 |
| swift-system | 1.6.4 | Apache-2.0 |

Exact revisions are recorded in
`ios/Sync.md.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Release archives include an SPDX SBOM generated from that lockfile. When
redistributing a modified libgit2 binary, comply with its linking exception and
provide the corresponding libgit2 source/build information.
