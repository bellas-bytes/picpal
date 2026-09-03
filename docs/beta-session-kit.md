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
