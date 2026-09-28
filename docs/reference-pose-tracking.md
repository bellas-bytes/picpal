# Reference body tracking

Reference photos and live camera samples use MediaPipe Pose Landmarker Lite through the already pinned SwiftTasksVision 0.10.21 package. Tracking runs on device; this feature adds no uploads or cloud dependency. The existing cloud comparison still covers background, lighting and viewpoint.

The selected photo is rendered upright (including mirrored UIImage orientations) before inference. Live NV12 camera buffers are converted to BGRA with a reused Core Image context and one reusable buffer on the existing serial observation queue. Mirrored live pixels are unmirrored before anatomical inference, then landmark positions are reflected back into display coordinates without exchanging joint identities. The Vision fallback follows the same convention. Sampling remains bounded at 3 Hz and drops frames while busy. A geometry revision discards the video tracker and its history. Video timestamps increase strictly even if input timestamps repeat or move backward.

Both paths map anatomical shoulders, elbows, wrists, hips, knees and ankles to the same bottom-left normalized coordinates. Visibility and presence must both be finite and at least 0.5; off-image and crop-edge joints are discarded. Local pose evidence requires one tracked body and one Vision person rectangle, with all four torso joints inside that rectangle. Multiple people never contribute a merged skeleton. A missing model or initialization failure uses Vision as a fallback; mismatched tracker backends cannot establish local pose alignment. Body inference failures leave pose unknown while preserving independently detected face evidence. Face or person detector failures make local reference analysis unavailable.

Coaching compares torso-relative positions and aspect-corrected 2D joint angles. Supported adjustments include raising/lowering or moving an arm outward/inward, bending/straightening an elbow or knee, leaning, and widening/narrowing stance. Framing corrections retain priority. Confidence gates, hysteresis, and the existing coordinator action stability remain in place. Missing joints yield uncertainty; a visible unsupported difference does not produce invented instructions. Measured pose alignment alone cannot establish an overall semantic match or authorize automatic capture.

## Bundled model

- File: `picpal/Resources/Models/pose_landmarker_lite.task`
- Pinned model: Google's float16 Pose Landmarker Lite, version 1
- Download: https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task
- SHA-256: `59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a`
- Official SDK guide: https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker/ios
- Model overview: https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker

The Xcode project explicitly includes the model in app resources; `project.yml` already includes the Models directory for project regeneration.

## Verification and limits

Synthetic tests cover index mapping, y conversion, confidence/occlusion, subject association, mirrored directional instructions, bends, arm placement, stance, and local-only captions. A simulator smoke test initializes the actual bundled model and runs image/video inference, including the real NV12 camera format and non-increasing input timestamps.

These checks do not establish physical-device directional accuracy, tracking latency, thermal behavior, or accuracy across different bodies/clothes/occlusion. A single image cannot reliably establish 3D depth, facing direction, fingers, or hidden joints. Projected angles can change with viewpoint; unsupported/ambiguous geometry remains unknown. Validate the cues with a consenting person on a phone before relying on them during a shoot.

Verified on the iOS simulator on 2026-09-24: the full Swift suite passed **762 tests in 86 suites** (`/tmp/picpal-pose-final.xcresult`). This includes the actual bundled-model smoke test and deterministic mirrored-pixel/landmark remapping regression. The bundled model's SHA-256 matched the source asset. Independent review found no remaining code findings; see [review report](reference-pose-tracking-review.md).

## Selfie references and orientation

A reference with one credible face but no supported torso uses an explicit face framing domain. Face rectangles are compared only to live face rectangles; body references continue to use person rectangles. Face framing can guide position and distance and report “Face framing aligned,” while unseen body pose remains unknown. It never enables automatic full-reference capture. Multiple or unassociated subjects remain unsupported, and detector failures do not become confident absence.

Reference labels describe upright displayed dimensions as Portrait, Landscape or Square. They do not infer historical camera posture. UIImage rotation and mirroring are baked into analysis pixels. The overlay and target boxes use the same aspect-fit transform within the measured preview viewport.

Phone portrait and both landscape orientations share preview, analysis-buffer and still-capture orientation. Flat/unknown readings retain the last valid orientation; gravity without a meaningful horizon stays neutral. Rotation stops automatic capture and speech, clears comparison evidence, restarts tracking, and drains buffered frames before resuming. Manual capture and camera switching remain available in the adaptive landscape layout.

Regression coverage includes face-only/no-body reference and live selection, ambiguous faces, detector failures, face/person domain mismatch, coordinator captions and capture gating, aspect-fit letterboxing, rotated and mirrored asymmetric pixels, landscape angle baselines and invalid flat horizons. Device rotation/preview/capture agreement and real selfie detector accuracy still require a phone check.

Selfie/orientation update verified on the iOS simulator on 2026-09-24: **777 tests in 90 suites passed** (`/tmp/picpal-selfie-final-v2.xcresult`, log `/tmp/picpal-selfie-final-v2.log`). The first full run caught a portrait floating-point regression from unnecessary angle normalization; preserving the unchanged portrait signal fixed it. The final run includes flat-horizon and independent live-face selection regressions.
