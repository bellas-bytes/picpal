# Reference pose tracking

## Intent

The user reports acceptable latency but generic coaching, and requests a body tracker SDK to power reference poses. Success is on-device reference/live pose extraction that produces specific, supported limb corrections. The user has requested autonomous execution and previously selected delegated implementation followed by independent review; routine design approval pauses are waived by that preference.

## Approach

Reuse the already linked MediaPipeTasksVision SDK and bundle Google's Pose Landmarker Lite model. Use image mode for selected references and video tracking on the bounded serial live-observation queue. Keep Apple Vision person rectangles for framing and ambiguity detection. Convert MediaPipe normalized coordinates to the existing bottom-left coordinate convention and preserve anatomical left/right identity. Use the same model on both sides, with a documented Vision fallback if SDK initialization is unavailable. Never invent confident joints on missing visibility/presence, failed inference, multiple people, or crop edges.

Expand ReferenceLocalComparator beyond arm-height and lean to elbow/knee bend, arm spread/horizontal hand placement and stance width using torso-relative positions and 2D angles. Keep confidence thresholds, geometry/mirroring normalization, framing priority, hysteresis and coordinator action stability. Wording names the subject's limb and a concrete adjustment; uncertain or unsupported depth/head/finger changes remain unknown. Do not claim reliable 3D reconstruction from one reference photo.

Local-only mode should distinguish measured pose alignment, a visible mismatch without a supported correction, and insufficient visible joints. Local pose alignment still cannot establish an overall semantic reference match or bypass automatic-capture safety. Existing cloud comparison continues to cover background, lighting and viewpoint. No new image uploads or cloud dependency are introduced.

## Integration and limits

Reuse SubjectObservationMonitor rather than add an independent competing frame consumer. Inference remains off-main, bounded/drop-if-busy, at the current sampling cadence. Reset tracking on geometry change. Include model provenance/checksum and ensure the Xcode app bundles it. Initialization must be exercised with the real model, not merely mocked adapter tests. Preserve the existing project and prior uncommitted work; do not commit, push, or deploy.

## Verification

Synthetic skeleton regression tests prove side/direction and correction selection for elbows, knees, arm placement, stance and mirroring. Low-confidence/occluded/cropped joints, ambiguous people, scale/aspect changes, stale observations and geometry resets cannot yield false confident matching. Adapter tests prove landmark index mapping, y-axis conversion, confidence handling and malformed input rejection. Integration tests prove tracked joints reach reference coaching/captions and non-reference camera behavior is preserved. Run focused regressions, full Swift suite, independent code review; device directional accuracy remains explicitly unverified until tested on a phone.

Sources: https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker/ios and Google's linked sample model download script. The repository already pins SwiftTasksVision 0.10.21, whose bundled MediaPipe headers include PoseLandmarker.
