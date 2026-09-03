# M7-2 Pre-Upload Checklist

**Date verified**: 2026-09-03
**Build**: 1.0.0 (1)

## Automated checks

| # | Item | Result | Notes |
|---|------|--------|-------|
| 1 | `MARKETING_VERSION = 1.0.0` in `project.yml` | PASS | `MARKETING_VERSION: "1.0.0"` confirmed in `settings.base` |
| 2 | `CURRENT_PROJECT_VERSION = 1` in `project.yml` | PASS | `CURRENT_PROJECT_VERSION: "1"` confirmed in `settings.base` |
| 3 | Entitlements — no unexpected entitlements present | PASS | No `.entitlements` file in project; iOS camera access is governed by `NSCameraUsageDescription` in `Info.plist` (no entitlement required on iOS). No push, iCloud, HealthKit, or debug entitlements present. |
| 4 | ATS: `NSAllowsLocalNetworking: true` in `Info.plist` | PASS | Present in `NSAppTransportSecurity` dict |
| 5 | ATS: `NSAllowsArbitraryLoads` absent from `Info.plist` | PASS | Key is not present |
| 6 | `proxy/.env` in `.gitignore` | PASS | Already present before this milestone |
| 7 | `ExportOptions.plist` in `.gitignore` | PASS | Added in this commit |
| 8 | `xcodebuild test` — 0 failures | PASS | 638 tests in 69 suites passed in 8.76 s (iPhone 16 simulator) |

## Manual steps required

| # | Item | Result | Action |
|---|------|--------|--------|
| 9 | Automatic signing — team and bundle ID match App Store Connect | MANUAL | Verify in Xcode → Signing & Capabilities that the selected team matches App Store Connect and bundle ID is `com.picpal.app` |
| 10 | Archive succeeds in Release configuration | MANUAL | Run `xcodebuild archive` (see M7-2 ticket for command) |
| 11 | IPA uploaded to App Store Connect | MANUAL | Use Xcode Organizer or `altool`/`notarytool` after archiving |
| 12 | App Store Connect app record created | MANUAL | Create via App Store Connect → My Apps with name "PicPal", bundle ID `com.picpal.app` |
| 13 | Metadata filled from `docs/app-store/metadata.md` | MANUAL | Copy name, subtitle, promotional text, description, what's new |
| 14 | Keywords set from `docs/app-store/keywords.md` | MANUAL | 94-character keyword string |
| 15 | Privacy nutrition label complete | MANUAL | Follow `docs/app-store/privacy-label.md`; camera + photos collected, not linked to identity, not for tracking |
| 16 | Screenshots uploaded (6.7" and 6.1" required) | MANUAL | At least one per required device size |
| 17 | Internal testers added and build enabled in TestFlight | MANUAL | App Store Connect → TestFlight → Internal Testing |
| 18 | Build installs and launches on device running iOS 17.0+ | MANUAL | Verify via TestFlight install |
| 19 | First-run consent screen appears on fresh install | MANUAL | Clear app data before testing |

## Files changed in this commit

- `.gitignore` — added `ExportOptions.plist` gate
- `ExportOptions.plist` — template created at project root (git-ignored)
- `docs/m7-2-checklist.md` — this file

## Notes

- The `NSAllowsArbitraryLoads` key is correctly absent; only `NSAllowsLocalNetworking: true` is set, permitting the local proxy server while keeping ATS enforced for all external connections.
- `ExportOptions.plist` is intentionally committed as a template (placeholder `YOUR_TEAM_ID`). It is git-ignored so the real file with the actual team ID is never committed.
- No warnings-treated-as-errors issues were observed in the test run; the AXCommon concurrency warnings in the test log are from the system accessibility framework, not from PicPal source code.
