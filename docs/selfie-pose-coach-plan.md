# Implementation Plan: Hybrid Selfie Pose Coach

## Overview
Make close-up references useful without requiring hips or legs. Compare measured head orientation and hand placement against the visible reference, coach one stable adjustment, and show one corresponding visual target. Existing optional cloud analysis identifies meaningful pose details; on-device observations remain the authority for measurable movement.

## Requirements
- Cropped selfies receive face/hand guidance independently of full-body tracking.
- Compare head yaw/roll and hand-to-face displacement with confidence and visibility gates.
- Conservatively identify a victory-like two-finger pose from visible hand joints; occlusion or ambiguous geometry is unknown.
- One instruction at a time, with measured progress and a subtle target for the active detail.
- Cloud prompts describe visible head/shoulder/hand relationships and prioritize them, using the existing schema and consent path.
- Existing person association, orientation, camera-flip, stale-evidence, and automatic-capture safeguards remain effective.

## Architecture Changes and Ownership
Core engineer owns:
- `picpal/Sources/Landmarks/SelfiePoseTracker.swift` (new): Apple Vision hand observation adaptation and face orientation evidence; pure geometry helpers for gesture evidence.
- `picpal/Sources/Reference/SelfiePoseComparator.swift` (new): face-relative hand displacement, head angles, visible-detail results and target selection.
- `picpal/Sources/Reference/ReferencePose.swift`, `LivePoseObservation.swift`: optional selfie observations with defaults so existing body consumers remain compatible.
- `picpal/Sources/Reference/ReferenceSession.swift`, `picpal/Sources/CameraCoaching/SubjectObservationMonitor.swift`: reference/live extraction in existing bounded detector work.
- `picpal/Sources/Reference/ReferenceLocalComparator.swift`, `ReferenceAnalysis.swift`, `ReferenceCoachingState.swift`, `ReferenceCoachingCoordinator.swift`: local detail evidence and stable cue/progress integration.
- Focused new and existing tests under `picpal/Tests/PicPalTests/`.

Root/UI owns:
- `picpal/Sources/VLM/ReferenceAnalysisPrompt.swift` and prompt/parser regression tests: explicit visible-only pose description and selfie-compatible phrasing.
- `picpal/Sources/App/CameraScreenModel.swift`, `ContentView+Reference.swift`, `picpal/Sources/UI/ReferenceOverlayView.swift`: propagate and render selected target/progress.

Recommended shared contract, to finalize before parallel editing: optional `PoseGuidanceTarget` containing normalized preview-display point (origin top-left) and accessibility label; optional target and progress caption on local evidence/decision. Keep raw detector coordinates in Vision space and convert exactly once. New fields need default nil values.

## Implementation Steps

### Phase 1: Measurable Close-up Evidence
1. Add pure, Sendable observation values for face yaw/roll, confident hand landmarks, and gesture state. Unknown remains distinct from absent/not-matching. Confidence/finite/bounds validation happens before comparison. Complexity medium; risk medium.
2. Extend reference and bounded live Vision work with hand detection, without changing subject counting to include hands. Face failures must not become measured zeros. Extraction must run off the main actor. Depends on step 1; complexity medium; risk medium.
3. Associate hands conservatively with the selected face/person. Do not choose arbitrary hands in group scenes or silently turn multiple people into one. Avoid relying on left/right handedness unless verified under mirroring. Depends on step 2; complexity medium; risk high.

### Phase 2: One Useful Cue
4. Compare hand placement in face-relative, aspect-corrected coordinates, so zoom and framing do not masquerade as articulation. Head roll/yaw compare only when both sides have evidence. Local rules must not demand invisible hips/legs. Depends on step 1; complexity medium; risk medium.
5. Gate victory-like evidence on visible confident finger chains; bent/occluded/foreshortened joints return unknown when classification cannot be supported. Hand movement is useful even if gesture classification is unknown. Depends on step 4; complexity medium; risk high.
6. Feed one prioritized detail into the existing coordinator. Significant framing correction remains first; then hand placement/gesture/head cues based on available reference details. Retain stable action keys, require newer consecutive observations before switching, and acknowledge completion only for the same detail. Clear immediately when evidence is stale/unknown or session/geometry changes. Depends on steps 4–5; complexity medium; risk high.

### Phase 3: Visual and Semantic Guidance
7. Render only the selected target in the camera preview; use the same geometry transform as the comparator. The overlay must not intercept flip, capture, or dismiss taps, and must clear with inactive evidence. Depends on step 6/shared contract; complexity low; risk medium.
8. Update existing cloud prompts to explain visible relationships such as hand beside mouth, head tilt, shoulder angle, and gesture; ignore cropped body parts. Use neutral/direct selfie-compatible instructions without inventing anatomical left/right. Keep existing strict dimensions/schema/consent validation. Independent of tracking implementation; complexity low; risk low.

## Unknown and Capture Semantics
Partial selfie detail success never sets full-body `poseAligned` true. Face-domain evidence retains `poseAligned=nil`; `referenceMatched` and automatic capture remain false under the current gate. A caption such as “Visible pose details aligned” is permitted only when all selected measurable details have valid aligned evidence; it must not claim the overall photograph matches. Missing gesture evidence cannot produce a gesture success caption. Unknown measurements remove their cue/target rather than preserving old instructions.

## Testing Strategy
- Unit tests: face-relative placement invariant to translation/scale; aspect ratio and mirroring; head direction; victory-like versus folded/open/occluded fingers; finite/confidence gates; two-hand ambiguity; selected-hand association.
- Coordinator tests: stable cue under small jitter, specific-detail progress, no invented whole-pose success, disappearance/staleness resets, session/flip/rotation resets, local measured differences override conflicting cloud inference.
- Integration tests: face-only selfie with no hips/legs produces actionable hand/head guidance; detector failure preserves independent usable evidence; rear-camera body coaching remains unchanged.
- Evaluation fixtures: anonymous numeric landmarks for peace sign beside cheek/mouth, lowered hand, tilted head, cropped fingers, two hands, mirrored selfie, portrait and landscape. Preserve a known desired action and forbidden action per fixture.
- Device acceptance: use the user's actual reference locally without committing the image. Verify peace-sign hand placement, head tilt, cue stability, progress, overlay alignment, camera flip, portrait/landscape, and consent-off operation. Record results separately from synthetic test counts.
- Run relevant focused tests, then full iOS suite and signed device build/install. Independent code review before final completion.

## Risks and Mitigations
- Geometric gesture detection can fail under foreshortening: conservative unknown state and useful placement coaching remain available.
- Wrong mirrored directions: display-coordinate targets and explicit portrait/landscape/front/rear fixtures; avoid unsupported anatomical claims.
- Cloud cues contradict local observations: maintain existing direct-measurement precedence and single-cue owner.
- Additional inference costs: reuse existing throttled queue, cap hands, avoid queuing overlapping work; measure actual phone responsiveness.
- Partial success accidentally enables capture: explicit face-domain negative tests and unchanged full-match gate.

## Success Criteria
- [ ] A close-up reference receives a specific visible-detail cue with no hips or legs required.
- [ ] Hand-to-face and head-angle corrections reduce the measured discrepancy.
- [ ] Gesture unknown is never reported as a verified peace sign.
- [ ] Only one stable cue and one relevant target appear; progress acknowledges the actual detail.
- [ ] Rotation, mirroring, camera switching, and evidence loss clear or transform guidance correctly.
- [ ] Partial selfie success never enables automatic capture or claims a full reference match.
- [ ] Existing tests plus meaningful new regressions pass; independent review and real-device checks are reported honestly.

## Implemented Handoff (2026-09-24)
The first slice uses face yaw/roll plus the index/middle knuckle centroid, not wrist position: the supplied peace-sign image has a low-confidence wrist but usable knuckles. Hand placement therefore survives a cropped or sleeve-covered wrist. Raw hand detection counts are preserved so dropping an uncertain second hand cannot create false single-hand correspondence. Gesture verification remains unknown for the supplied photo's occluded finger evidence; local hand placement and head coaching still operate.

The coordinator debounces instruction changes, clears unmeasurable details, and holds a named completion acknowledgement for two seconds only while that detail stays aligned. Existing full-body matching is retained; no new shoulder-only comparator is added in this slice. Cloud semantics are improved through the existing profile/comparison prompts, not a new structured gesture schema. No model download or dependency was added.

Initial focused validation: 33 tests across three suites passed in `/tmp/picpal-selfie-coach-focused-v2.xcresult`. Final gesture-spread, opposite-yaw, and acknowledgement-dwell refinements require the root's ensuing full-suite run. Independent root-authored numeric evaluations cover scale/translation, mirroring, cropped preview targets, gesture geometry, and automatic-capture safety. A third reviewer agent could not start because the agent thread limit was reached; root reviewed core code and the implementing agent reviewed root's prompt/UI integration. Physical-device acceptance is still required and must not be inferred from numeric tests.
