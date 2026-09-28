# PicPal: first iPhone run

Assessment date: September 11, 2026. Current milestone: run on Isabella's own iPhone, with on-device coaching first.

## Assessment

The project is a substantial native iOS coaching prototype: camera preview, tilt/exposure/blur/framing signals, spoken cues, body and group analysis, reference-photo overlays, camera switching, and exposure controls are implemented. The baseline simulator suite passed 654 tests with no failures.

The first deployment check uncovered a packaging bug: the face and hand model files existed in the repository but were absent from the app bundle. XcodeGen ignored the target-level `resources` entry. The fix includes them under `sources` with `buildPhase: resources`. A regression test checks that both models are present and nonempty in the running app bundle; it failed against the original build.

Existing device signing settings are now also in `project.yml`, so regenerating the project preserves them.

After the fix, all 655 tests passed (658 executions including parameterized cases), with zero failures or skips. The generated project and packaging change also passed independent code review. A successful simulator run does not verify live camera or MediaPipe inference on the phone.

The corrected Debug build signed successfully and was installed on Isabella's paired iPhone 17 (`com.picpal.app`). Both model files were verified in the device build. Automatic launch was blocked by iOS because the phone was locked; unlock and open PicPal to complete the hands-on checks below. Live camera behavior and model initialization on the device remain unverified.

## Try on your iPhone

1. Open PicPal and choose **Stay on-device only** on first launch. If you previously enabled cloud coaching, switch it off in the gear menu.
2. Allow camera access. Point at a well-lit person, hold still, then gently tilt the phone and change framing. Listen for short coaching cues.
3. Try the camera-flip button. Tap the preview for focus/exposure controls; double-tap to reset exposure bias.
4. Select a reference photo, check its overlay, then dismiss it.
5. Background and reopen the app. Confirm the preview and coaching resume. Test a few minutes for heat, responsiveness, and excessive or contradictory voice cues.

The new camera iteration adds a still-photo shutter, one-shot Auto capture, and add-only Photos saving (see the latest section below). Simulator tests cannot establish camera quality, landmark accuracy, battery use, or real-device stability.

## Next iterations

### Coaching output follow-up

The user reported a working preview and moving level line but no visible or audible coaching. The output audit found captions were hidden in diagnostics and overwritten with a dash on every cooldown tick; speech also left the default audio category unchanged. Captions now appear above the preview and persist for four seconds across cooldown ticks. Mute and Test voice are available directly on the camera screen. Speech commands run on the main queue and configure playback/spoken-audio output with mixing, permitting speech in silent mode. Device media volume and audio routing still determine audibility.

All 658 tests passed, including three regression tests that failed before the fixes. The final layout built successfully for simulator and device. Simulator interaction checks verified the visible test caption, mute toggle, and nonoverlapping diagnostics. The user subsequently confirmed Test voice and automatic tilt coaching both work on the phone.

### More forgiving tilt coaching

Following device feedback that tilt was too sensitive, the default coaching tolerance now starts corrections above 6° and stops them below 4°. Previously these boundaries were 2.5° and 1.5°. The gap prevents repeated corrections as the phone moves slightly around a boundary. Small correctable tilts remain quiet; raw angle measurement and the rotating level guide are unchanged.

### Portrait tilt direction

After a report of repeated advice, the sensor audit found the app was treating Core Motion's longitudinal-axis Euler roll as the portrait horizon angle. The hardware adapter now derives the horizon from screen-plane gravity, using `atan2(gravity.x, -gravity.y)`. Near-flat poses suppress horizon correction because the gravity projection is unreliable. The existing 6°/4° coaching tolerance remains. Sensor-boundary regression tests cover both directions, level posture, and a nearly flat phone; all 663 tests pass. Review found no issues. Confirmation on the phone is still needed for the user's exact repeated-command symptom.

1. **Device usability:** verify camera permission denial recovery, front-camera mirroring, reference matching, tap-to-focus accuracy, and live audible coaching. Debug controls now sit above the exposure layer; simulator checks confirmed they respond to taps.
2. **Photo-taking flow:** verify the new manual shutter, photo orientation/quality, Photos permission retry, and one-shot Auto capture on the phone.
3. **Optional cloud coaching:** configure a reachable proxy endpoint in Settings → Cloud Coaching. The default `http://localhost:4000/analyze` points to the iPhone itself, so use the Mac's LAN address for device testing. Do not embed an Anthropic API key in the app.
4. **Shared/public release:** add an app icon and privacy-policy URL, reconcile privacy statements with reference-image uploads and crash reporting, configure crash reporting in the shipped build, and validate an archive. Existing beta crash evidence is still incomplete.

## Backend assessment

The proxy is development-only: fixed port, no client authentication, no lockfile, and a 200-call counter stored on the server filesystem. It has contract tests, but no production deployment or operational test coverage. Its error text suggests restarting resets the limit even though the count persists. Before hosting it publicly, add access control, deployable configuration, dependency/security checks, reliable quota management, bounded uploads and safe errors. Confirm upstream image-retention terms before publishing retention claims.

## Reference understanding — September 16

Reference coaching now separates fast local measurements from semantic cloud comparison. On-device processing covers subject framing and a conservative subset of torso and major-limb pose. It can guide a supported adjustment or report framing alignment, but cannot establish a complete reference match from a similar rectangle or partial pose. It does not locally assess lighting, viewpoint, depth, hands, facial expression, or every crop.

When cloud coaching is globally enabled and the user consents for the active reference, the app requests a structured reference profile and structured two-image comparisons. A full match requires fresh supported evidence for every applicable framing, pose, viewpoint, lighting, and background dimension, plus 1.5 seconds of stable local alignment. Unknown evidence blocks the match. Manual shutter capture remains available; automatic capture in reference mode requires that full match and safe physical capture conditions, so local-only reference sessions remain manual.

The comparison freshness window is 8 seconds. Scheduling is event-driven for initial comparison, settled scene changes, and verification of an active action, with the existing 8-second minimum request cadence. The product target is at most three cloud calls per minute on average including the profile and retries. That average has not been measured and is not a hard cap.

To use the development proxy on a phone, run the proxy on the Mac with its required API key, place both devices on the same network, then enter `http://<mac-lan-address>:4000/analyze` under Settings → Cloud Coaching and tap **Save and check connection**. Do not use `localhost`: on an iPhone it points back to the phone. Changing the endpoint disables cloud coaching until the user makes a fresh privacy choice; selecting a reference also requires explicit consent before either image is uploaded.

Validation status: 742 Swift tests pass (`/tmp/picpal-reference-iteration5.xcresult`), plus 8 proxy tests and 3 evaluation-harness tests. The pre-change baseline was 696 Swift tests. The repository includes specifications for 30 evaluation scenarios, but actual licensed images and human reviews are absent. The semantic benchmark, calls-per-minute and freshness measurements, and real-phone direction/mirroring, crop/orientation, consent, offline, manual-capture, and automatic-capture checks remain incomplete.

## Build again

Open `PicPal.xcodeproj`, choose the PicPal scheme and your paired iPhone, then Run. Use the existing signing team, or select your own team if building on another account. Regenerate with `xcodegen generate` after changing `project.yml`.

Run Xcode builds/tests sequentially when using the same DerivedData directory; concurrent builds can lock its database.

For later distribution, consult Apple's current [upload requirements](https://developer.apple.com/news/upcoming-requirements/), [app icon instructions](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon/), and [review guidelines](https://developer.apple.com/app-store/review/guidelines/). Personal device testing does not require an App Store submission.

## Still-photo camera iteration — September 11

The user approved a still-only camera with automatic camera assistance, a familiar bottom shutter bar, and reference selection from Photos. Implemented:

- Full-resolution AVCapturePhotoOutput, portrait orientation, original encoded-data saving via add-only Photos permission, and capture/save feedback. A failed save retains the original in memory for retry and prevents accidental replacement.
- Optional one-shot auto-capture after 1.5 seconds of fresh person detection, framing, acceptable tilt, stable exposure and a steady phone. It disarms on capture and interruptions; manual shutter bypasses coaching readiness.
- Full Body / Portrait framing styles, bounded automatic zoom, subject-focused automatic exposure/focus, white balance, manual zoom, automatic flash toggle and 3-second timer. Portrait does not add blur effects.
- Bottom-right system Photos picker to select or replace reference images. Matching uses fresh Vision coordinates independently of generic shot-style rules.
- Independent bounded person detection and exposure analysis outside the scene-change gate so unchanged scenes cannot leave stale capture readiness.

Simulator UI checks confirm layout and Photos picker presentation. Automated coverage includes auto-capture interruption/gaps/one-shot behavior, reference matching, zoom bounds, timer cancellation, duplicate capture suppression, and failed-save retry without recapture. Device-only checks remain: actual still photo/save, front/rear framing and orientation, focus/exposure convergence, and auto-capture with a real person. These checks are not established by simulator tests.

### Minimal phone check

1. Tap the white shutter once, allow adding photos, and check the image in Photos.
2. Tap the bottom-right thumbnail and choose a reference.
3. Clear the reference, point at a well-lit person, and tap Auto capture. Hold the phone steady: the ring should fill and take exactly one photo. Move or remove the person before the ring completes: it must reset.

Readiness means the measurable framing checks passed; it does not mean an objectively perfect photo. Auto zoom is digital on the selected wide camera and is capped at 2×. Actual distance is not measured in meters. Saving failures are retained in memory, so keep PicPal open until retry succeeds.

Final automated result: **691 tests passed**, 701 executions including parameterized cases, zero failures or skips (`/tmp/picpal-camera-final.xcresult`). Independent code review found no remaining actionable issues. Simulator interaction verified auto-capture arming, disarming through the Photos picker, reference selection, and recoverable extraction failure. A device Debug build signed and installed successfully on the paired iPhone. The final follow-up changes only the generic reference error wording.

## Portrait orientation follow-up — September 12

User confirmed photos save, then supplied a device screenshot showing the preview and saved thumbnail rotated 90° despite upright controls. The camera implementation had hard-coded a 90° angle for preview, analysis, and still capture. Apple documents that native sensor rotation varies across cameras, including iPhone 17. Each connection now requests semantic portrait orientation instead, preserving fixed portrait framing without assuming a sensor angle. Automatic subject focus now uses the preview layer's coordinate converter, as manual taps already do.

The supported portrait-orientation API is deprecated in the current SDK but expresses this fixed-orientation requirement without hard-coded hardware assumptions. A future migration can use the new static RotationCoordinator orientation API when available in the supported SDK. Camera output orientation still requires confirmation on the actual front and rear cameras; simulator tests cannot validate sensor mounting.

Source: https://developer.apple.com/forums/thread/813548

## Repeated auto-capture follow-up — September 12

User confirmed the live preview orientation is correct, then requested friend-style repeated photos that tolerate small adjustments. This supersedes the earlier one-shot dwell behavior. Auto capture now uses a 0.25-second readiness check and remains active after saving, with at least 0.8 seconds between requests plus hardware/save time. Its yellow ring indicates active shooting without a filling countdown; Stop and the session photo count stay visible. Stop works while a photo is saving; the in-flight photo finishes, with no next shot.

A separate capture-motion check permits gentle three-axis rotation below 0.7 radians/second (including sideways panning) without the older motion-settling dwell. Fast movement pauses readiness, while fresh person detection, framing, tilt, exposure and optics checks still apply. Sheets/backgrounding/errors stop the session. The previous one-shot gate tests fail against the requested behavior; replacement tests cover quick/repeated requests, pauses, stale frames, motion tolerance and stopping during save.

Validation: 696 tests passed (706 executions), zero failures; independent review approved. The device build reached codesigning but is waiting for the macOS keychain prompt while the Mac is locked. Installation of this iteration is pending unlock/signing approval.

Stationary scenes and transient errors receive a sparse refresh after 20 seconds, still subject to consent, freshness and the shared budget. This avoids indefinite waiting without polling at the maximum request rate.
