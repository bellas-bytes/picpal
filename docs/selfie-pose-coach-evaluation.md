# Selfie pose coach evaluation

## Scope

The new local path compares hand placement relative to the face, head roll/yaw, and conservative visible victory-like finger geometry. It works alongside body tracking and optional cloud reference interpretation. It does not require hips or legs for head/hand cues, and partial detail agreement does not establish a complete pose match.

The UI shows one hand-position target in preview coordinates and a specific progress acknowledgement. Cloud prompts prioritize visible hand/head relationships and allow selfie-compatible instructions through the existing schema and consent path.

## Evidence

A local macOS Vision diagnostic on the supplied selfie found one hand. Wrist confidence was approximately 0.18, while index and middle knuckle confidences were approximately 0.59 and 0.56. The production adapter therefore anchors placement on those knuckles rather than requiring the obscured wrist. Several folded finger landmarks were below the confidence threshold: this image supports hand placement but not a verified complete victory gesture. The image is not stored in this repository.

Independent numeric evaluation cases cover face-relative translation/scale invariance, displayed directions with both camera mirror settings, preview cropping and top-left target coordinates, visible victory versus open palm, occlusion returning unknown, aspect-correct gesture geometry, and repeated partial agreement never enabling automatic capture. These establish geometry/control behavior, not real-world detector accuracy.

Full simulator verification passed **803 tests in 93 suites**, with both `SelfiePoseCoachTests` and `SelfiePoseEvaluationTests` executed (`/tmp/picpal-selfie-coach-full.xcresult`, `TEST SUCCEEDED`). The existing offline reference-coaching evaluator's three tests also passed. No cloud visual benchmark was run or claimed.

## Review

The implementation agent reviewed the root's overlay, prompt, and evaluation changes; the root reviewed the tracking/comparison/coordinator changes. A separate third reviewer could not be started because the session reached its agent-thread limit.

Review corrections include preserving raw hand counts when one hand has low confidence, clearing an old cue when its detail becomes unknown, stabilizing opposite movement instructions, avoiding wrist/knuckle correspondence changes, aspect-correcting finger geometry, and correcting open-palm/opposite-head-turn instructions.

## Device checks

After installation, validate the same reference with hand raised/lowered, head tilted in both directions, fingers partially hidden, front/rear cameras, and portrait/landscape. Confirm that targets align visually, progress is readable, and responsiveness remains acceptable. These checks require live phone use; simulator unit tests and the macOS still-image diagnostic cannot establish them. Existing body tracking still provides broader limb guidance; this addition does not infer unobserved shoulders, fingers, or limbs.
