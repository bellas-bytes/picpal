# Reference pose tracking review

Independent review, 2026-09-24. Scope was compared explicitly with `/tmp/picpal-pose-baseline-20260924.tar.gz`; pre-existing uncommitted architecture changes were excluded. Reviewed the design, implementation plan, changed production files, tests and Xcode registration. No application code was edited by the reviewer.

No confirmed correctness or security findings remain. Follow-up integration review identified an implicit front-camera assumption: a model receiving reflected pixels must infer physical anatomical sides correctly. The reviewed correction explicitly unmirrors live inference pixels and remaps positions to display coordinates while preserving anatomical joint keys. MediaPipe uses a Core Image horizontal reflection; Vision fallback uses `.upMirrored` input orientation followed by the same output remap. Rectangle association remains in display coordinates.

Evidence inspected:

- Reference and live extraction share the MediaPipe joint-index, bottom-left-coordinate and confidence adapter. Missing/nonfinite confidence, crop-edge coordinates and multiple poses cannot provide positive joint evidence. Backend identity prevents comparing Vision and MediaPipe poses.
- Both extraction paths require a single person rectangle containing all four reliable torso joints before exposing pose joints. Live processing remains on the existing serial, drop-if-busy queue at the existing sampling cadence; BGRA conversion reuses one buffer. Geometry revisions recreate video tracking; old observation revisions remain available for downstream rejection.
- Capture rotates live buffers upright. Reference orientation is baked into pixels before both inference providers see it. Anatomical joint keys are preserved through canonical live inference and display remapping, while comparator geometry normalization handles mirrored live coordinates. Synthetic tests cover left/right elbow and knee correction reversal with mirrored coordinates. The new deterministic mirror regression checks asymmetric red/blue pixel locations and reflected landmark positions without changing joint keys or confidence.
- Framing retains priority. New elbow/knee bend, arm placement and stance corrections use torso-normalized 2D measurements. Unknown joints cannot produce full pose alignment. Local-only captions distinguish measured alignment, unsupported mismatch and missing evidence without granting overall match or automatic capture.
- The tracker, tests and model are registered in the Xcode source/resource phases. Model SHA-256: `59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a`. No new image upload or cloud dependency was introduced.

Verification: execution was owned by the implementation agent; no competing Xcode run was started. The first focused attempt encountered a comparator `acos` overload build error, corrected by explicitly converting the cosine to `Double`. The subsequent focused run passed 53 tests in 4 suites (`/tmp/picpal-pose-green2.xcresult`), including real bundled model initialization and blank image, video and NV12-buffer inference. Mirror regression red evidence is `/tmp/picpal-pose-mirror-red2.log`: 6 tests executed, with exactly 3 expected failures in unmirroring/remapping assertions before implementation. Final full suite passed **762 tests in 86 suites**, including the mirror regression and real model smoke test (`/tmp/picpal-pose-final.xcresult`; corresponding log reports `TEST SUCCEEDED`). The bundled app model checksum matches the source asset.

Physical-device directional accuracy, tracking quality under occlusion, and sustained camera performance remain unverified. The orientation regression currently checks upright metadata and dimensions, rather than rendered color locations; pixel-level assertions would strengthen coverage but are not a confirmed implementation defect.

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: APPROVE, including the scoped mirror correction and successful full-suite verification.
