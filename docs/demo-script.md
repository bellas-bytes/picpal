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

---

## Body Signals (M2) — requires physical iPhone

> All M2 body cues require a real device with the MediaPipe model files bundled.
> The Simulator runs without body signals (LandmarkOrchestrator degrades gracefully).

### Lens obstruction cue
- Cover the camera lens partially with a finger.
- **Expected**: spoken "Move your hand away from the lens" fires promptly.
- Remove finger → cue clears within one cadence cycle (≤200ms at 5fps).

### Awkward crop cue
- Stand in frame and move an arm or leg to the very edge of the frame.
- **Expected**: spoken "Adjust your framing — something's getting cut off".
- Move limb back inside frame → cue clears.

### Gaze-away cue
- Stand in frame with your face clearly visible, then turn your head ≥30° sideways.
- **Expected**: spoken "Look toward the camera" after 3 stable frames (~600ms).
- Turn back to face the camera → cue clears.

### Headroom cue
- Stand in frame with head near the top edge (less than ~5% headroom).
- **Expected**: spoken "Move the camera up a little".
- Raise the camera until ~10% headroom → cue clears.

### Zero-false-cue validation
- Remove yourself completely from frame (empty scene or point at a wall).
- **Expected**: no body cues fire; only M1 tier-0 cues (tilt/blur/exposure) remain active.
- Run for ≥30 seconds to confirm sustained silence on body channel.

### Thermal budget (3–5 min session)
- Run a continuous session with a person visible in frame.
- Monitor the debug overlay for Tier-0 FPS and thermal state.
- **Expected**: FPS ≥ 25, thermal state stays nominal (no throttle warning).

---

## M3 — Tier 2 VLM aesthetic coaching

> All M3 scenarios require a proxy running at `http://localhost:4000/analyze` unless noted.
> Simulator builds exercise the wiring but make no network calls (VLM gate fires only
> on settled scenes — the Simulator motion gate is open immediately, so gate checks run,
> but the `AnthropicVLMClient` will surface network errors that are safely absorbed by
> the offline-degradation path).

### Aesthetic cue (basic)
*(manual — PENDING_DEVICE_RUN)*

1. Start the proxy (`cd proxy && node index.js`).
2. Launch PicPal on a physical iPhone. Open the debug overlay (tap bug icon).
3. Point the camera at a well-lit subject and hold steady for ≥ 8 seconds.
4. **Expected**: debug overlay shows `VLM: in-flight` briefly, then a `VLM remark` row
   with a short coaching phrase (e.g., "Move the subject to the left third").
5. If `VLMSettings.isOnDeviceOnly` is false, a spoken cue fires via TTS within ~12 s.

### Stale-suppression
*(manual — PENDING_DEVICE_RUN)*

1. Hold the camera steady over a subject until a VLM request dispatches (overlay shows
   `VLM: in-flight`).
2. Immediately pan away to a completely different scene while the request is in flight.
3. Repeat ≥ 10 times.
4. **Expected**: 10/10 — no aesthetic cue fires for the panned-away frame.
   The stale-suppressor rejects the response because the scene signature changed.

### Offline degradation
*(manual — PENDING_DEVICE_RUN)*

1. Start a session with proxy running. Confirm at least one VLM cue fires.
2. Disconnect Wi-Fi / enable Airplane Mode.
3. Continue shooting for 2–3 minutes.
4. **Expected**: Tier-0/0.5 cues (tilt, blur, exposure, framing, body) continue
   uninterrupted. Debug overlay shows no `VLM remark` and no `VLM: in-flight`.
   No TTS error is spoken. After 3 consecutive failures the session disables Tier 2
   permanently (no retry storms).

### On-device-only toggle
*(manual — PENDING_DEVICE_RUN)*

1. Open the Settings sheet (gear icon, bottom-right corner).
2. Disable "Cloud composition coaching" (toggle off → `isOnDeviceOnly = true`).
3. Hold the camera steady over a subject for ≥ 30 seconds.
4. **Expected**: debug overlay shows no `VLM: in-flight` indicator. Proxy logs (server
   console) receive zero new requests. Tier-0/0.5 cues continue normally.
5. Re-enable the toggle and confirm VLM requests resume within one cadence cycle.

### Cost check (session budget)
*(manual — PENDING_DEPLOYMENT)*

1. Start the proxy with request logging enabled.
2. Run a 5-minute session with a person visible in frame.
3. After the session, count total proxy calls from the server log.
4. **Expected**: call count ≤ 50 (default `VLMRequestGate` budget for a session).
   Actual count depends on novelty rate; 10–20 is typical for a stable scene.

### Thermal and FPS non-regression
*(manual — PENDING_DEVICE_RUN)*

1. Run two back-to-back 5-minute sessions:
   - Session A: `isOnDeviceOnly = true` (Tier 2 disabled).
   - Session B: `isOnDeviceOnly = false` (Tier 2 active, proxy running).
2. Record FPS and thermal state from the debug overlay for each session.
3. **Expected**: Tier-0 FPS ≥ 25 in both sessions. Thermal state stays `nominal`
   or `fair` in both sessions. No statistically significant regression in FPS when
   Tier 2 is active (VLM runs on a utility queue; camera queue is unblocked).

---

## Phase 2 — M6 Validation

### Scenario A: Tilt predictive check

**Setup**: device tilted 5° or more off level.

1. Observe: corrective tilt cue fires ("Tilt left/right a little").
2. Slowly correct the tilt.
3. **Expected**: when angle begins decreasing, predictive hint fires ("almost level").
4. **Expected**: engine remains silent during the wait window (no repeated cues).
5. Continue correcting until level.
6. **Expected**: positive confirmation fires ("that's it") once the device levels.

**Pass criteria**: hint fires once, silence during window, confirmation on level.

### Scenario B: Exposure predictive check

**Setup**: scene underexposed (cover ambient light source or aim at dark area).

1. Observe: corrective exposure cue fires ("Too dark — find more light").
2. Gradually uncover/improve the light source.
3. **Expected**: predictive hint fires ("light's getting better, hold a moment").
4. **Expected**: silence during wait window.
5. Complete the improvement until exposure reads OK.
6. **Expected**: positive confirmation fires ("nice light").

**Pass criteria**: hint fires once, silence during window, confirmation on recovery.

### Scenario C: Group photo check

**Setup**: two or more people stand in front of camera.

1. Stand naturally — one person partially off-frame on the left.
2. **Expected**: group cue fires ("someone's getting cut off on the left") instead of single-subject body cue.
3. Widen the frame to include everyone.
4. **Expected**: no group edge-cutoff cue; engine may be silent or fire aesthetic/framing cue.
5. Have one person step away — only one person in frame.
6. **Expected**: group mode deactivates; single-subject body cues resume normally.

**Pass criteria**: group cue replaces single-subject cue in group mode; single-subject cue resumes after group dissolves.
