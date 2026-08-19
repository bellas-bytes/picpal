# PicPal — M7 Tickets (TestFlight Beta + App Store Submission)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md)
**Date**: 2026-08-11
**Platform**: iOS
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: PicPal ships publicly on the App Store as a free app. TestFlight beta runs with real users; the exit criterion is ≥3 days crash-free on all enrolled devices. All submission artifacts are complete before review submission.

## Locked decisions

1. **Free at launch** — no in-app purchase, no subscription, no paywall. No `StoreKit` code in the initial submission.
2. **iOS 17.0 minimum** — `IPHONEOS_DEPLOYMENT_TARGET = 17.0`. Documented rationale: Vision framework APIs and Swift structured concurrency toolchain require iOS 17.
3. **A15 Bionic minimum** — documented in App Store description and support page; not enforced as a device capability key (AVFoundation and Vision run on A14, just more slowly). Recommended device note shown at first launch for A14 and older chips.
4. **TestFlight exit criterion**: ≥3 consecutive calendar days with zero crashes on all enrolled beta devices before App Store submission. Tracked in `BETA_LOG.md`.
5. **One-person team submission** — no App Store Connect team management, no external testers via public link until internal testing is clean. External TestFlight link opened only after exit criterion is met.
6. **Privacy nutrition label reflects M1–M5.5 feature set** — camera, microphone (not used but AVFoundation declares it; mark as not used), photo library (reference photo picker; data not linked to identity). No contact data, no location, no tracking.

## Conventions (carried from M0–M6)

- Swift 6 strict concurrency; no changes to signal or cue engine code in this milestone.
- **Swift Testing only** — new unit tests added in M7 cover only launch-gate and chip-detection logic.
- 300-line file limit.
- All string literals appearing in App Store metadata live in `docs/app-store/` — no metadata embedded in source code.

## Execution order

```
M7-0 (App Store metadata + nutrition label)  ← can run in parallel with M7-1
M7-1 (beta session kit + BETA_LOG bootstrap)
  ↓
M7-2 (TestFlight distribution — requires M7-0 and M7-1 artifacts)
  ↓
M7-3 (exit criterion verification + App Store submission checklist)
```

---

## M7-0 — App Store metadata + privacy nutrition label
**Size**: M · **Deps**: none

**Goal**: Write all App Store listing copy and configure the privacy nutrition label in App Store Connect. Nothing in this ticket changes source code.

### Directory structure

```
docs/app-store/
├── metadata.md       ← master source for all listing copy
├── keywords.md       ← 100-character keyword string
├── support-url.md    ← support page content (GitHub Discussions or static page)
└── privacy-label.md  ← nutrition label questionnaire answers
```

### `docs/app-store/metadata.md`

**App name**: PicPal
**Subtitle** (30 chars max): Real-time photo framing coach
**Promotional text** (170 chars max, updated without review): Instant, voice-guided coaching while you frame your shot — no AI cloud calls until you say so.

**Description** (4000 chars max):
```
PicPal watches your camera in real time and tells you — out loud — exactly what to adjust before you tap the shutter.

Tilt it a bit. Back up. The light's getting better.

It's like having a photographer standing next to you, but it runs entirely on your phone.

HOW IT WORKS
PicPal reads your camera 30 times per second using on-device computer vision. It checks tilt, exposure, blur, and how well you're framing your subject. When something's off, it speaks a short, specific cue — not a score, not a badge, just the one thing that will help most right now.

REAL-TIME BODY COACHING
Point at a person and PicPal adds body-aware coaching: is their face turning away? Are they getting cut off at the ankles? Are they positioned well in the frame?

REFERENCE PHOTO MODE
Want to replicate a pose from a photo you love? Import it and PicPal compares your live frame to the reference shot. A ghost overlay shows how close you are; when you match, it tells you.

SMART CLOUD ANALYSIS (OPTIONAL)
Enable the optional cloud tier for a deeper read — composition, background distractions, lighting quality — from a vision-language model. This tier is off by default. You turn it on, and you can turn it back off at any time. PicPal never sends your camera to the cloud without your explicit consent.

PREDICTIVE COACHING
When a signal is actively improving — you're slowly levelling the tilt, the light is recovering — PicPal waits instead of nagging. It says "almost level" and lets you land it.

GROUP PHOTOS
Coaching scales to group shots. When two or more people are in frame, PicPal switches to group-level cues: "someone's getting cut off on the right — back up a bit."

WORKS GREAT ON
iPhone 12 and later (A14 Bionic chip or later). Best on iPhone 13 or later (A15 Bionic).

PRIVACY
PicPal processes your camera on-device. The optional cloud tier sends still frames only — never video — and only when you have consented and are in an active session. Reference photos are never stored or sent anywhere. Nothing is ever tracked or linked to your identity.
```

**What's new** (first release): First release.

### `docs/app-store/keywords.md`

Keyword string (100 chars, comma-separated, no spaces after commas):
```
photo,framing,camera,coach,AI,portrait,composition,tilt,exposure,blur,pose,reference,guide,voice
```

### `docs/app-store/privacy-label.md`

| Data type | Collected? | Linked to identity? | Used for tracking? | Notes |
|-----------|-----------|--------------------|--------------------|-------|
| Camera | Yes | No | No | On-device processing; optional cloud sends still frames only |
| Photos | Yes | No | No | Reference photo picker — selected photo never stored |
| Microphone | No | — | — | AVFoundation declares entitlement; microphone is not used |
| Contact info | No | — | — | |
| Location | No | — | — | |
| Identifiers | No | — | — | |
| Usage data | No | — | — | Telemetry export is local only; not sent to any server |

**Data not linked to you** (camera still frames, when cloud tier is enabled by user):
- Purpose: App Functionality
- Retention: Not stored beyond the current session response

### `project.yml` changes

Verify or set:
```yaml
settings:
  IPHONEOS_DEPLOYMENT_TARGET: "17.0"
  MARKETING_VERSION: "1.0.0"
  CURRENT_PROJECT_VERSION: "1"
  PRODUCT_BUNDLE_IDENTIFIER: "com.picpal.app"
```

**Acceptance criteria**

- [ ] `docs/app-store/metadata.md` contains app name, subtitle, promotional text, and description matching the locked copy above.
- [ ] `docs/app-store/keywords.md` is ≤100 characters.
- [ ] `docs/app-store/privacy-label.md` covers all data types; camera and photos marked as collected, not linked to identity, not for tracking.
- [ ] `IPHONEOS_DEPLOYMENT_TARGET = 17.0` in `project.yml`; confirmed in Xcode build settings after regeneration.
- [ ] `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1` in `project.yml`.
- [ ] `PRODUCT_BUNDLE_IDENTIFIER` is set and does not contain `example`, `test`, or the Xcode template default.
- [ ] Description accurately reflects the M1–M5.5 feature set (no features mentioned that aren't implemented).

---

## M7-1 — Beta session kit + BETA_LOG
**Size**: S · **Deps**: none

**Goal**: Produce the full TestFlight beta session protocol and bootstrap the crash tracking log used to enforce the 3-day exit criterion.

### `docs/beta-session-kit.md`

```markdown
# PicPal Beta Session Kit

**Build**: 1.0.0 (1)
**Target devices**: iPhone 12 or later with iOS 17.0+
**Recommended**: iPhone 13 or later (A15 Bionic)

## Before your session

1. Close all other apps.
2. Ensure the device is charged ≥50%.
3. Open PicPal. If first run, read and accept the consent screen.

## Core scenarios (run each at least once)

### 1. Solo portrait — outdoor
- Find a person. Frame them standing, head to toe.
- Expected: Within ~3s, you hear a coaching cue (tilt, headroom, crop, or "looks good").
- Move the phone until all cues stop. Tap the shutter.

### 2. Solo portrait — indoor, tricky light
- Backlit subject (window behind them).
- Expected: exposure cue ("the light is behind them — try moving them or the camera").

### 3. Reference photo mode
- Tap the reference photo button (top-right, person-on-rectangle icon).
- Select a photo from your library. Wait for the ghost overlay to appear (<2s).
- Try to match the framing.
- Expected: ghost overlay fades and turns green when you're close; you hear "that's it" or similar.
- Swipe down or tap X to dismiss.

### 4. Group photo (2–3 people)
- Frame 2–3 people; intentionally let one person's shoulder be cut off at the right edge.
- Expected: "someone's getting cut off on the right — back up a bit."
- Back up until coaching stops.

### 5. Predictive coaching — tilt
- Tilt phone ~15° and slowly bring it level at a steady rate.
- Expected: app says "almost level" (not the corrective "level it out") while you correct; says "that's it" on arrival.

### 6. Blur / shake
- Hold the phone and shake it lightly.
- Expected: "hold steady" cue within ~1s.

### 7. Lens obstruction
- Cover part of the lens with a finger.
- Expected: "something's covering the lens" cue within ~2s.

### 8. Background (app switching)
- Mid-session, press the Home button and wait 10s.
- Return to PicPal.
- Expected: no crash; session resumes; cues resume within ~3s.

### 9. Optional: cloud VLM tier
- In Settings > Privacy, enable cloud analysis.
- Frame an interesting scene.
- Expected: within ~5–8s, a cloud-sourced cue arrives (composition, background, or lighting quality).
- Disable cloud analysis and verify cues revert to on-device-only.

## Report

After your session, note:
- Device model and iOS version
- Any crash (forced close, freeze, or unexpected quit)
- Any cue that fired at the wrong time or felt incorrect
- Anything surprising or confusing

Send feedback via TestFlight's built-in feedback form or reply to the beta invite email.
```

### `BETA_LOG.md` (project root)

```markdown
# PicPal Beta Crash Log

Exit criterion: ≥3 consecutive calendar days, zero crashes, all enrolled devices.

| Date | Build | Device | iOS | Crash? | Notes |
|------|-------|--------|-----|--------|-------|
| (first beta day) | 1.0.0 (1) | — | — | — | Beta distributed |

## Exit status: NOT MET
```

**Acceptance criteria**

- [ ] `docs/beta-session-kit.md` covers all 9 scenarios (solo portrait, tricky light, reference photo, group photo, predictive coaching, blur, obstruction, background, optional cloud).
- [ ] Each scenario states device action, expected cue or behavior, and what a failure looks like.
- [ ] `BETA_LOG.md` exists at project root with the header, table structure, and "Exit status: NOT MET" footer.
- [ ] `BETA_LOG.md` is committed to the repo and is NOT git-ignored.

---

## M7-2 — TestFlight distribution
**Size**: S · **Deps**: M7-0, M7-1

**Goal**: Archive and upload a release build to App Store Connect; add internal testers; distribute via TestFlight.

### Pre-upload checklist (run before archiving)

- [ ] `xcodebuild test` passes with 0 failures.
- [ ] `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1` confirmed in Xcode.
- [ ] Signing: Automatic signing enabled; team and bundle ID match App Store Connect.
- [ ] Entitlements: only `com.apple.security.device.camera` present; no debug entitlements.
- [ ] `NSAllowsLocalNetworking: true` in `Info.plist` ATS config (proxy only); no `NSAllowsArbitraryLoads`.
- [ ] `proxy/.env` is in `.gitignore` and not present in the archive.
- [ ] Build succeeds with `Release` configuration and no warnings treated as errors (fix any remaining warnings first).

### Archive and upload

```bash
xcodebuild archive \
  -project picpal.xcodeproj \
  -scheme picpal \
  -configuration Release \
  -archivePath build/PicPal.xcarchive
```

```bash
xcodebuild -exportArchive \
  -archivePath build/PicPal.xcarchive \
  -exportPath build/PicPal-export \
  -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` (create at project root, git-ignored):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
```

Upload via Xcode Organizer or `altool` / `notarytool` — whichever is configured in the dev environment.

### App Store Connect setup (manual steps)

1. In App Store Connect → My Apps → create new app (if not already created): name "PicPal", bundle ID from `project.yml`, primary language English.
2. Fill all metadata from `docs/app-store/metadata.md`.
3. Set keywords from `docs/app-store/keywords.md`.
4. Complete privacy nutrition label from `docs/app-store/privacy-label.md`.
5. Upload screenshots (at least one per required device size; minimum: 6.7" and 6.1" required by App Store).
6. Under TestFlight → Internal Testing: add yourself and any other internal testers.
7. Enable the build for internal testing (no review required for internal).

**Acceptance criteria**

- [ ] Build archives without error in Release configuration.
- [ ] IPA is uploaded to App Store Connect (build appears in TestFlight within ~10 minutes).
- [ ] Internal testers receive TestFlight invite and can install the build.
- [ ] TestFlight build installs and launches on at least one device running iOS 17.0+.
- [ ] First-run consent screen appears on a fresh install (cleared app data).
- [ ] `ExportOptions.plist` is git-ignored (contains team ID, no secrets but conventionally excluded).

---

## M7-3 — Exit criterion verification + App Store submission
**Size**: S · **Deps**: M7-2 (beta running)

**Goal**: Track beta stability against the 3-day exit criterion; submit to App Store once met; tag the release commit.

### BETA_LOG maintenance

After each beta day, update `BETA_LOG.md`:

| Date | Build | Device | iOS | Crash? | Notes |
|------|-------|--------|-----|--------|-------|
| Day 1 | 1.0.0 (1) | iPhone 14 Pro | 17.6 | No | — |
| Day 2 | 1.0.0 (1) | iPhone 14 Pro | 17.6 | No | — |
| Day 3 | 1.0.0 (1) | iPhone 14 Pro | 17.6 | No | Exit criterion MET |

When the criterion is met, update the footer:

```markdown
## Exit status: MET — 3 consecutive crash-free days. Ready for App Store submission.
```

### If a crash occurs

- Record in `BETA_LOG.md` (Crash? = Yes, with symbolicated crash report summary in Notes).
- Reset the consecutive-day counter to 0.
- Fix crash in code; increment `CURRENT_PROJECT_VERSION` (e.g., `2`); rebuild + upload.
- New beta build resets the counter.

### App Store submission checklist

Run after exit criterion is met:

- [ ] `BETA_LOG.md` shows ≥3 consecutive crash-free rows; footer updated to "MET".
- [ ] All metadata in App Store Connect matches `docs/app-store/metadata.md` exactly.
- [ ] Privacy nutrition label is complete and saved in App Store Connect.
- [ ] At least one screenshot uploaded per required device size.
- [ ] Age rating questionnaire completed (expected: 4+; no violent content, no gambling, no adult content).
- [ ] Pricing: Free.
- [ ] App Review notes (in App Store Connect submission form): explain camera usage and the optional cloud tier consent flow. Include: "Camera is used only for live on-device analysis. Cloud tier is off by default; user enables it explicitly in-session."
- [ ] Build selected for submission is the same build that passed the beta exit criterion.
- [ ] Submit for review.

### Post-submission

After App Store review approval:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Update `BETA_LOG.md`:

```markdown
## App Store status: APPROVED — v1.0.0 live on <date>
```

**Acceptance criteria**

- [ ] `BETA_LOG.md` has at least 3 consecutive No-crash rows before submission.
- [ ] App Store Connect shows the build in "Waiting for Review" or later status.
- [ ] `v1.0.0` git tag exists and points to the submitted build's source commit.
- [ ] `BETA_LOG.md` is updated with "App Store status: APPROVED" when review passes.
- [ ] No App Store rejection for privacy, metadata, or technical issues (if rejection occurs, add to `BETA_LOG.md` under "Rejection notes" and resolve before resubmitting).
