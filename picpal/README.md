# PicPal

See the [living architecture, decision log, and interview notes](../docs/architecture-and-decisions.md) for the system diagram, engineering tradeoffs, incident stories, validation evidence, and open questions. Update that document when making meaningful architectural changes.

An iOS photo-framing coach with live camera analysis, spoken guidance, and reference-photo overlays. Requires iOS 17 or later. Take still photos with the shutter, or start Auto capture for repeated photos after a brief 0.25-second readiness check. Photos are saved to your library; the bottom-right Photos button selects reference pictures. Portrait is a framing style, without background-blur effects.

Open `../PicPal.xcodeproj`, select the **PicPal** scheme and your iPhone, then Run. Choose **Stay on-device only** for the first session. Optional cloud coaching needs a separately configured proxy reachable from the phone.

Reference mode gives immediate local framing and limited 2D pose guidance. Local-only mode does not establish an overall reference match and cannot start automatic reference capture; use the manual shutter at any time. With cloud coaching enabled and explicit consent for the selected reference, PicPal builds a structured reference profile and periodically compares the reference with the live frame. A full match requires fresh supported evidence for framing, pose, viewpoint, lighting, and background.

For development, install and start the proxy with `cd ../proxy`, `npm install`, `ANTHROPIC_API_KEY=<key> npm start`. Then open Settings → Cloud Coaching and save `http://<your-mac-lan-address>:4000/analyze`. Use the Mac and iPhone on the same network; `localhost` on the phone refers to the phone. **Save and check connection** probes the corresponding `/health` endpoint. Saving a new endpoint turns cloud coaching off so the user can make a fresh privacy choice, and every selected reference still needs explicit upload consent.

See the [device readiness assessment](../docs/device-readiness.md) for a first-run checklist, known limitations, and next iterations. `../project.yml` is the XcodeGen project definition; regenerate from the repository root with `xcodegen generate` when changing it.

## Camera controls

- White shutter: take a photo; it does not require a coaching “ready” result.
- Auto capture: starts a photo session with repeated shots while framing, tilt, exposure, and gentle movement remain usable. A yellow ring marks the active session; Stop stays available even during saving. Photos are spaced by at least 0.8 seconds and never overlap. Sheets, backgrounding, camera/style changes, or manual focus/zoom stop the session.
- Bottom-right Photos: choose or replace a reference image using the system picker.
- Zoom: tap supported magnification buttons or pinch the preview; tap or hold the current zoom readout for fine adjustment. Zoom starts manual and stays within the active camera’s range.
- Reference opacity: adjust the ghost image from 0–100%; the choice is remembered.
- Focus: with a reference loaded, choose all visible details, Hand, Head or Shoulders when those measurements are available. Changing focus clears previous coaching progress.
- Tap the preview: manual focus/exposure; use the sun slider for brightness. Double-tap restores automatic focus/exposure and zero brightness bias.
- Top bar: automatic flash on/off where supported, 3-second timer, voice mute, and settings.

Photos permission is add-only. If saving fails, PicPal holds the original photo in memory and offers Retry; keep the app open until it saves. Camera quality, mirroring, and live auto-capture still need physical-device checks.

Cloud comparisons use an 8-second stale limit and an event-driven schedule constrained by the existing 8-second minimum request cadence. The target of at most three calls per minute on average includes reference-profile calls and retries; it is a measurement target, not a hard cap. For the latest recorded software verification and its implementation revision, see the [living architecture document](../docs/architecture-and-decisions.md#what-has-actually-been-verified). The 30-scenario evaluation manifest currently has no test images or human reviews, so phone validation and the semantic benchmark remain incomplete.

Stationary scenes and transient errors receive a sparse refresh after 20 seconds, still subject to consent, freshness and the shared budget. This avoids indefinite waiting without polling at the maximum request rate.

Reference coaching uses an on-device MediaPipe body tracker for both the selected photo and live preview. It can suggest concrete elbow/knee, arm-placement and stance adjustments when joints are visible, with conservative unknown states for ambiguous evidence. See [reference pose tracking](../docs/reference-pose-tracking.md) for model provenance, fallback behavior and device-validation limits.

## Specific pose feedback

Selfie guidance compares hand placement relative to the face, visible finger spread and hand angle, head tilt/turn, and supported shoulder angle. The coach ranks supported corrections, keeps one cue stable, and verifies progress for that detail. Cropping differences need not block face-relative guidance; partial detail alignment does not establish a whole-reference match or enable automatic capture. Missing or ambiguous landmarks remain unknown. Palm direction and depth are not inferred.

The [pose-feedback evaluation tools](../evals/pose-feedback/README.md) validate private labeled reference/live pairs, replay real pixels through the native pipeline, and score exported decisions. The real manifest is deliberately empty; software tests and rendered fixtures are not real-photo accuracy evidence. Model training is deferred until a rights-cleared benchmark identifies a recognition gap. See the [release evidence](../evals/pose-feedback/release-report.md).
