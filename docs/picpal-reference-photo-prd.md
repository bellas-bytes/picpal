# Product Requirements Document: Reference Photo Mode

**Version**: 1.0
**Date**: 2026-08-11
**Author**: Sarah (Product Owner)
**Quality Score**: 91/100
**Companion to**: [picpal-prd.md](picpal-prd.md) · [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md)
**Roadmap slot**: M5.5 — after scene-descriptor caching (M5), before predictive/multi-person coaching (M6)

---

## Implemented behavior — September 16, 2026 (supersedes conflicting requirements below)

The current implementation is deliberately more conservative than the original PRD. Where later sections describe rectangle-based full matching, an automatic match from local landmarks, or automatic reference capture from local evidence, this section takes precedence.

- On-device reference coaching compares subject framing and a supported subset of 2D torso and major-limb pose. It can say **Framing aligned** or give a supported arm/lean adjustment. It does not assess lighting, viewpoint, depth, hands, facial expression, or every crop, and it never turns a similar person rectangle into a full-reference match.
- **Reference matched** requires a fresh, schema-validated cloud profile and two-image comparison covering framing, pose, viewpoint, lighting, and background, plus stable local alignment for 1.5 seconds. Unknown or unsupported evidence blocks a full match.
- The manual shutter remains available regardless of reference readiness. Automatic reference capture is allowed only after the full-match policy passes and physical capture conditions are safe. Local-only users therefore retain manual capture but do not receive automatic reference capture.
- Cloud reference work requires the global cloud setting and explicit consent for the active reference. Changing the service endpoint disables cloud coaching and requires a fresh choice. Reference image bytes, derived profiles, and model text remain session-memory-only and are invalidated on reference, consent, camera-geometry, or session changes.
- Cloud output is structured: a reference profile records evidence, confidence, assessability, and applicability for each dimension; a comparison records reference/live evidence, `matched`/`different`/`unknown`/`notApplicable`, and at most one concrete action. Responses are validated before use.
- Comparisons older than 8 seconds at delivery are stale. Requests use the existing 8-second minimum cadence with event-driven opportunities for the first comparison, settled changes, and action verification. The product target is at most three cloud calls per minute on average, including the profile and retries; this is an unverified measurement target, not a hard cap implied by the cadence.

Automated validation passes 742 Swift tests, 8 proxy tests and 3 evaluation-harness tests; the pre-change baseline was 696 Swift tests. Real-phone direction/mirroring and crop/orientation checks, app-session freshness/call-rate measurements, and the semantic image benchmark are not complete. The checked-in evaluation scaffold defines 30 scenarios, but contains no actual images or human reviews and must not be presented as a passed visual benchmark.

---

## Executive Summary

Reference Photo Mode lets a user hold up a photo they want to replicate and receive real-time coaching that closes the gap between their live view and the reference. The user picks any photo from their library — a professional shot, a location reference, a pose they admired — and PicPal overlays it as a ghost on the viewfinder while coaching them toward a match.

This is a dual-engine feature: Apple Vision / MediaPipe landmark comparison runs every frame for instant pose and framing deltas ("move them more to the left third"), while the VLM is called periodically with both images together for richer context ("the reference has much warmer light — you may need to wait for the sun to shift, or try the other side of the room"). The user gets the same tiered latency they expect from the rest of PicPal, now directed at a specific target rather than abstract best practices.

Match confirmation is multimodal: the ghost overlay tints green and fades when landmark deltas and coaching signal convergence, paired with a spoken "nice — that looks like the reference shot." The user can also dismiss the reference manually at any time.

---

## Problem Statement

**Current Situation**: PicPal coaches users toward generic best practices — level horizon, subject in the thirds, good headroom. But many users already have a specific shot in mind: a Pinterest pose, a photo they loved from a previous trip, a composition a friend shared. Today there is no way to tell PicPal "I want *this*."

**Proposed Solution**: A photo library picker that activates Reference Photo Mode. In this mode, the picked photo is analyzed for pose landmarks and scene composition, overlaid as a semi-transparent ghost on the live camera view, and used as the coaching target. The coaching voice shifts from "here's what's wrong" to "here's what's different from the reference."

**Business Impact**: Strong differentiation — no major camera coaching app offers live reference matching. Directly serves the "Sharing Sam" persona (replicating a pose they want to give someone) and a new motivation: "I saw this photo and want to recreate it." Highly shareable moment: the before/after of "I matched it."

---

## Success Metrics

**Primary KPI (new for this feature):**
- **Match achievement rate**: in a moderated "replicate this reference" task, ≥60% of users achieve a coaching-confirmed match (ghost turns green + voice fires) within 60 seconds.

**Carry-forward KPIs (must not regress):**
- Perceived real-time responsiveness: ≥70% of users agree feedback came fast enough to act on.
- Non-annoyance: median cues per episode ~1–3.

**Supporting metrics:**
- **Reference mode adoption**: ≥30% of beta testers try reference mode at least once during the M7 TestFlight phase.
- **VLM cost per reference session**: ≤ 3 VLM calls per 60-second reference session on average (landmark layer handles the real-time loop; VLM provides periodic context).

**Validation**: M7 TestFlight includes an explicit "replicate this reference photo" task with a provided reference image. Telemetry export captures match-event timestamps and VLM call counts.

---

## User Personas

### Primary: Sharing Sam (promoted to reference use case)
- **Role**: Handed a phone with instructions like "take a photo of me like this one" (showing a reference on another device or printed).
- **Goals**: Replicate a specific pose or framing exactly, not just "take a good photo."
- **Pain Points**: Has to alternate between looking at the reference and looking at the viewfinder; no way to compare in real time.

### Secondary: Casual Cam (recreation use case)
- **Role**: Wants to recreate a composition from a travel photo, a Pinterest image, or their own previous best shot.
- **Goals**: Learn how to replicate shots they admire; explore what makes a composition work.
- **Pain Points**: Can see the reference and the live view but can't tell what specifically needs to change.

---

## User Stories & Acceptance Criteria

### Story 1: Activating Reference Photo Mode

**As a** photographer who has a target shot in mind
**I want** to pick a reference photo and see it overlaid on my live camera view
**So that** I can align my shot visually while still seeing the live scene.

**Acceptance Criteria:**
- [ ] A reference photo button is visible in the camera UI (icon: a layered-photos or split-square symbol); tapping it opens the iOS `PHPickerViewController`.
- [ ] The user selects one photo; the picker closes and Reference Photo Mode activates immediately.
- [ ] The reference photo is displayed as a ghost overlay on the live camera preview at ~30% opacity (named constant: `ReferenceOverlay.defaultOpacity = 0.30`).
- [ ] The reference is letterboxed/pillarboxed to match the live camera aspect ratio without distortion.
- [ ] An X button (top-right corner of the overlay, or a dedicated "exit reference" button) dismisses the overlay and deactivates reference mode; swiping down on the overlay also dismisses it.
- [ ] Reference mode can be re-entered at any time by tapping the button again.

### Story 2: Real-time pose and framing coaching toward the reference

**As a** photographer in Reference Photo Mode
**I want** instant spoken coaching about how the live view differs from the reference
**So that** I can make adjustments without looking away from the viewfinder.

**Acceptance Criteria:**
- [ ] On activation, Vision runs on the reference *still image* (one-time, not per-frame) to extract pose/body keypoints, face landmarks, and composition (subject bounding box, aspect ratio of subject vs. frame, headroom, horizontal placement). These are stored as `ReferencePose`.
- [ ] Each live frame's landmark output is compared to `ReferencePose` to produce a `PoseDelta` (per-joint offset + composition diff).
- [ ] The `ReferenceCoach` converts `PoseDelta` into cues at the appropriate priority level (below obstruction and stability; above generic composition):
  - Subject placement: "move them more to the left" / "they need to be a bit higher in the frame"
  - Headroom: "more space above their head — tilt up a touch"
  - Pose proximity (body angle/crop): "the reference has a tighter crop — step in closer"
  - Face yaw: "in the reference they're facing the camera more — have them turn back toward you"
- [ ] Cues are suppressed when the delta is within a named tolerance (`PoseDelta.matchThreshold`) — the app stays quiet when the user has it right.
- [ ] When no person is detected in the live view, reference coaching falls silent and a one-time cue fires: "no subject yet — reference matching pauses until someone steps in."
- [ ] Reference coaching integrates into the existing `CueEngine` priority stack: does not block Tier-0 emergency cues (obstruction, severe tilt, extreme exposure).

### Story 3: VLM context coaching toward the reference

**As a** photographer in Reference Photo Mode
**I want** occasional richer coaching that captures what makes the reference special
**So that** I understand the "why" behind the framing, not just the mechanical delta.

**Acceptance Criteria:**
- [ ] On settle events (same gate as the existing `VLMRequestGate`), the VLM is called with both the reference image and the current live frame.
- [ ] The VLM prompt instructs the model to compare the two images and describe what concrete change would bring the live view closer to the reference (framing, light direction, distance, mood).
- [ ] VLM response is filtered through the existing stale-suppression path; responses whose live frame has changed materially are discarded.
- [ ] VLM reference cues are priority-ordered the same as existing aesthetic cues (lowest priority; never preempt Tier-0/0.5 landmark cues).
- [ ] When reference mode is inactive, the VLM reverts to the standard single-frame aesthetic prompt — no behavior change outside reference mode.

### Story 4: Reference privacy consent

**As a** user with cloud VLM coaching enabled
**I want** to know my reference photo will be sent to the cloud before it happens
**So that** I can make an informed choice, especially if the photo contains someone else's face.

**Acceptance Criteria:**
- [ ] When the user picks a reference photo *and* cloud VLM coaching is enabled (ConsentGate already given): a one-time consent sheet is shown per session — "To help match the reference, this photo will be sent to the coaching service along with your live camera frames. Proceed?" with "Yes, use reference" and "On-device only" options.
- [ ] "On-device only": reference mode activates but VLM is set to on-device-only for this session's reference calls (landmark coaching still works fully). This preference is session-scoped, not persisted.
- [ ] "Yes, use reference": reference photo is eligible for VLM calls. Consent is remembered for the rest of the session (no repeat prompt on subsequent references picked in the same session).
- [ ] If cloud VLM is already off (user previously chose on-device-only at ConsentGate), no extra prompt is shown — reference mode works purely via landmarks.
- [ ] Reference photos are never persisted beyond the current app session. They are not logged, cached to disk, or transmitted outside the VLM call path.

### Story 5: Match confirmation

**As a** photographer who has aligned the shot with the reference
**I want** a clear signal that I've matched it
**So that** I know when to take the shot.

**Acceptance Criteria:**
- [ ] When `PoseDelta` drops within `matchThreshold` for ≥ `ReferenceOverlay.matchConfirmationFrames` consecutive frames (default: 8 frames ≈ ~0.5s at 15fps landmark cadence):
  - The ghost overlay tints green (overlaid tint: `ReferenceOverlay.matchTintColor`) and fades to 15% opacity.
  - A positive spoken cue fires: "nice — that looks like the reference shot" (or equivalent warm variant).
- [ ] If the match breaks (delta exceeds threshold again after confirmation), the overlay returns to normal opacity and coaching resumes.
- [ ] The match confirmation cue respects the existing cue cadence cap — it won't fire again within `CueEngine.defaultCueCooldownSeconds` of the previous confirmation.
- [ ] Named constants for all thresholds: `PoseDelta.matchThreshold`, `ReferenceOverlay.matchConfirmationFrames`, `ReferenceOverlay.matchTintColor`, `ReferenceOverlay.matchOpacity = 0.15`.

---

## Functional Requirements

### Core Feature: Reference Photo Mode

**Component: `ReferenceSession`**
- Created when a user picks a reference photo; destroyed when dismissed.
- Stores: the reference `UIImage`, the one-time-extracted `ReferencePose`, and the per-reference VLM consent state.
- `@MainActor final class`, passed as a dependency to `ReferenceCoach` and the overlay view.

**Component: `ReferencePose`**
- `Sendable` struct produced by running Vision on the reference `UIImage` once at activation.
- Contains: body keypoints (`[VNHumanBodyPoseObservation.JointName: CGPoint]`), face landmarks (centroid + yaw estimate), subject bounding box in normalized coordinates.
- Computation runs on a background queue; `ContentView` receives it via a callback and stores it in `@State`.

**Component: `PoseDelta`**
- `Sendable` struct. Computed each landmark frame: diff between `ReferencePose` keypoints and live `BodySignal` keypoints.
- Fields: `subjectOffsetX: Float` (normalized, left/right), `subjectOffsetY: Float` (up/down), `headroomDelta: Float`, `cropDeltaRelative: Float` (how much closer/farther vs. reference framing), `faceYawDelta: Float`.
- `var isWithinThreshold: Bool` — true when all components are within named tolerance constants.

**Component: `ReferenceCoach`**
- Converts `PoseDelta` to `[Cue]` at `CuePriority.bodyPositioning`.
- Stateless; called from `SignalFrameAccumulator`'s callback path alongside the existing body-signal cue path.
- Priority: any Tier-0 emergency cue preempts `ReferenceCoach` output.

**Component: `ReferenceOverlayView`**
- SwiftUI `View` layered in the ZStack between the camera preview and the debug overlay.
- Renders the reference `UIImage` at `defaultOpacity`, respecting aspect ratio.
- Observes `isMatchConfirmed: Bool` from the parent; applies green tint + `matchOpacity` on confirmation.
- Dismiss: X button (top-right) or `.gesture(DragGesture().onEnded { ... swipe down })`.

**VLM integration: two-image prompt**
- `FrameEncoder` extended to accept an optional `referenceImage: UIImage?`.
- When present, the VLM request payload includes two images: reference first, live frame second.
- A new system prompt variant is selected: `VLMPrompt.referenceMode` — instructs the model to describe what would bring the live view closer to the reference.
- Existing `VLMPrompt.aestheticCoaching` is used when no reference is active.

### Out of Scope
- Camera capture of a physical reference (photo library only for this milestone).
- Multiple simultaneous reference photos.
- Saving the matched shot alongside the reference for before/after comparison (post-launch idea).
- Animated GIF or video reference (still photo only).
- Auto-selecting the best matched moment and capturing automatically.

---

## Technical Constraints

### Performance
- Reference photo Vision inference (one-time at activation): must complete within 500ms on A15 Bionic. Run on `probeQueue` (same background queue used by `LandmarkOrchestrator`); display a brief loading state during extraction.
- `PoseDelta` computation per live frame: pure arithmetic on pre-extracted keypoints — must add <2ms to the landmark callback path.
- Ghost overlay rendering: a simple `Image(...).opacity(...)` composited in SwiftUI — no additional GPU work beyond what AVFoundation preview already does.
- VLM calls with two images: reference image is resized to the same resolution as the live frame before encoding (`FrameEncoder`'s existing downscale logic applies). Net payload increase: ~2× per VLM call. Still async, still stale-suppressed.

### Security & Privacy
- Reference photo is held in memory for the session only. Never written to disk, never logged.
- If cloud VLM is enabled: per-reference consent prompt fires once per session. User can choose on-device-only for reference calls without affecting the rest of their cloud coaching preference.
- `PHPickerViewController` is used (not `UIImagePickerController`) — reads only the selected photo, no library access grant required beyond what iOS already handles.
- VLM calls with the reference photo are governed by the same proxy as all other VLM calls — keys off-device, no reference images persisted server-side (enforced by proxy design from M3).

### Integration
- `ReferenceSession` is owned by `ContentView` (`@State var referenceSession: ReferenceSession?`).
- `ContentView+Session.swift` extended with `activateReferenceMode(image:)` and `deactivateReferenceMode()`.
- `SignalFrameAccumulator` callback extended: if `referenceSession` is non-nil, call `ReferenceCoach.cues(for: poseDelta)` and merge into the landmark cue set.
- `VLMOrchestrator` receives `referenceImage: UIImage?` as a dependency; if non-nil, selects `VLMPrompt.referenceMode`.

### Technology Stack
- `PHPickerViewController` (iOS 14+, privacy-preserving photo picker).
- Vision framework (same as existing body pose analysis) for one-time reference extraction.
- SwiftUI `ZStack` + `Image` + `.overlay` for ghost rendering.
- No new external dependencies.

---

## MVP Scope & Phasing

### This milestone (M5.5): Core reference photo mode
- Photo library picker activation.
- One-time `ReferencePose` extraction (Vision on still).
- Ghost overlay with dismiss gesture.
- `ReferenceCoach` generating landmark-delta cues in real-time.
- Per-reference VLM consent prompt.
- Two-image VLM prompt for periodic context coaching.
- Match confirmation (green-tint ghost + voice).

### Post-launch enhancements
- Camera capture of a physical reference (point at a screen or printed photo and capture it as the reference).
- Before/after comparison view (matched shot saved alongside reference for sharing).
- Session history of references used.
- Auto-capture when match is held for 1s (opt-in).

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Reference Vision inference blocks the camera UI on first activation | Med | Med | Run on `probeQueue`; show a brief "analyzing reference..." loading state; <500ms on A15 Bionic |
| Ghost overlay obscures the live scene, making it hard to frame | Med | Med | Default 30% opacity is intentionally subtle; X button always visible; user can swipe to dismiss instantly |
| PoseDelta landmark matching fires false "match" on similar but wrong poses | Med | Med | `matchConfirmationFrames` requires 8 consecutive frames — transient coincidences won't confirm |
| Two-image VLM calls increase cost significantly | Low | Med | Reference VLM calls are gated by the same `VLMRequestGate` cadence (8s default); stale-suppressed; at ≤3 calls/60s the cost delta is small |
| User doesn't understand the per-reference consent prompt | Low | Med | Copy is short and concrete: "This photo will be sent to the coaching service." "On-device only" option is clearly labeled and doesn't break the experience |
| Reference mode coaching drowns out existing Tier-0 cues | Low | High | `ReferenceCoach` output is inserted at `bodyPositioning` priority — obstruction, stability, and exposure cues all rank above it |

---

## Dependencies & Blockers

**Dependencies:**
- M2 landmark pipeline (`BodySignal`, `LandmarkOrchestrator`, `PresenceGate`) — `ReferencePose` extraction uses the same Vision models; `PoseDelta` compares against live `BodySignal`.
- M3 VLM pipeline (`VLMOrchestrator`, `FrameEncoder`, `VLMRequestGate`) — two-image prompt extends `FrameEncoder`; reference consent wraps the existing `VLMOrchestrator` call path.
- M4-3 `ConsentGate` — per-reference consent is layered on top of (not replacing) the existing cloud consent.
- M5 scene-descriptor caching — should be complete first so the cache handles the live-frame VLM calls; reference-mode VLM calls bypass the cache (two-image calls have a different key space).

**Known Blockers:**
- None — all dependencies are built and on `develop`.

---

## Appendix

### Glossary
- **ReferencePose**: the extracted keypoints and composition metadata from the reference still image. Computed once on activation; the coaching target for the session.
- **PoseDelta**: the per-frame diff between `ReferencePose` and the live `BodySignal` output. Drives `ReferenceCoach` cue selection.
- **ReferenceCoach**: the stateless component that maps `PoseDelta` fields to spoken cues.
- **Ghost overlay**: the reference photo rendered semi-transparently over the live camera preview; tints green when a match is confirmed.
- **Per-reference consent**: a one-time session prompt that gates sending the reference photo to the cloud VLM, separate from (and layered on top of) the existing `ConsentGate`.
- **Two-image VLM prompt**: a VLM request that sends both the reference image and the current live frame, using a new `VLMPrompt.referenceMode` system prompt that instructs the model to describe what would close the gap.
- **Match confirmation**: the multimodal signal (green ghost tint + spoken cue) emitted when `PoseDelta.isWithinThreshold` holds for `matchConfirmationFrames` consecutive frames.

### References
- [picpal-prd.md](picpal-prd.md) — Phase 1 PRD (tier architecture, cue priority stack, VLM stale-suppression)
- [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md) — M5 (caching), M6 (predictive + multi-person), M7 (App Store)
- M3 `VLMOrchestrator` and `FrameEncoder` — extended by this feature for two-image calls
- M4-3 `ConsentGate` — per-reference consent is additive to this gate

---

*This PRD was created through interactive requirements gathering with quality scoring to ensure comprehensive coverage of business, functional, UX, and technical dimensions.*

Stationary scenes and transient errors receive a sparse refresh after 20 seconds, still subject to consent, freshness and the shared budget. This avoids indefinite waiting without polling at the maximum request rate.
