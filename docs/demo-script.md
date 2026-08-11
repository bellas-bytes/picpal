# PicPal M1 Demo Script

## Setup

1. Launch PicPal on a physical iPhone (or simulator with camera permission granted).
2. Point the camera at a well-lit indoor scene with a visible subject.
3. Ensure audio is on and volume is audible.
4. Confirm the debug overlay is visible (level line, thirds grid, subject box).

---

## Cue Demonstrations

### Tilt cue
- Tilt the device ~10° clockwise.
- **Expected**: spoken "Tilt left a little" + level line shown tilted on overlay.
- Straighten device → cue stops after the cooldown period.

### Blur cue
- Shake the device gently while pointing at the scene.
- **Expected**: spoken "Hold still" within ~150ms of motion.
- Hold the device steady → cue stops.

### Exposure cue
- Point the camera directly at a bright window or light source.
- **Expected**: spoken "Too much light — step back or angle away".
- Return to a normally lit scene → cue clears.

### Framing cue
- Position a clear subject in the far left or far right of the frame.
- **Expected**: spoken nudge cue ("Nudge right" or "Nudge left").
- Move the subject toward a rule-of-thirds intersection → cue clears.

### Good frame (silence)
- Hold the device level, sharp, correctly exposed, with subject on a thirds line.
- **Expected**: silence + green level indicator in the overlay. No spoken coaching.

---

## Mute Toggle

1. Tap the microphone button (bottom of the camera view).
2. **Expected**: coaching speech stops immediately; overlay cues still update.
3. Tap again to unmute → coaching resumes on the next qualifying cue.

---

## Session Budget (optional stress test)

- Run a continuous 3–5 minute session.
- Monitor the debug overlay for FPS and thermal state.
- **Expected**: FPS ≥ 25 throughout, no thermal-throttle warning in the overlay.
