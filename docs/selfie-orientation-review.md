# Selfie and orientation review

Reviewed against `/tmp/picpal-selfie-baseline-20260924.tar.gz`, which includes the earlier user changes. Review covers reference extraction, independent live face/body detection, subject association, face/person comparison domains, coordinator capture restrictions, normalized reference image geometry, orientation propagation, stale geometry invalidation and adaptive controls. No source changes made by reviewer.

## Findings

[RESOLVED — MEDIUM] Flat-device fallback becomes a false landscape tilt

File: `picpal/Sources/Motion/MotionManager.swift:132`

`CoreMotionDataSource.makeSample` returns `roll = 0` when the screen-plane gravity projection is below 0.15 because no reliable horizon exists. The original landscape correction applied a ±90-degree offset to that fallback. The correction now carries `isHorizonValid` through `MotionSample` and bypasses orientation correction for invalid horizons before smoothing. Source re-review confirms this resolves the finding; delegate-level regression tests cover both landscape directions.

## Evidence and limits

- `/tmp/picpal-selfie-focused.log`: 40 tests across three suites passed, `TEST SUCCEEDED`. This covers selfie selection and existing reference session/comparator behavior.
- Face-only comparison supplies framing evidence with unknown pose. Coordinator full-match dwell still requires `poseAligned == true`, so face framing alone cannot auto-capture.
- Reference framing and displayed ghost image both use aspect fit into the preview; live boxes use the preview's aspect-fill crop. Reference normalization preserves orientation before extraction and display.
- Geometry changes clear local/cloud comparison evidence and reset tracker revisions. Camera transition gating drains queued buffers before accepting subsequent evidence.
- Re-reviewed extracted `LivePoseObservation.measured`, which the production monitor calls: body failure preserves independent face evidence; failed face detection makes analysis unavailable; multiple or unassociated subjects remain ambiguous.
- First full-suite run (`/tmp/picpal-selfie-final.log`): 773 tests, one exact floating-point assertion failure in `MotionManagerTests.readingIsDeliveredToDelegateAfterFeed` (0.09999999999999999 versus 0.1). Re-reviewed correction preserves portrait roll unchanged and only normalizes landscape offsets.
- Final full-suite run (`/tmp/picpal-selfie-final-v2.log`, result `/tmp/picpal-selfie-final-v2.xcresult`): **777 tests in 90 suites passed; TEST SUCCEEDED**. Includes new coordinator, live-evidence selection and flat-landscape tests. Reviewer read the result directly; no competing Xcode job was started.
- Real-phone detection quality, camera orientation and mirrored output in both landscape directions, transition timing and shutter/control visibility remain device checks. Static review and synthetic tests cannot establish those hardware behaviors.

## Review Summary

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass (1 resolved) |
| LOW | 0 | pass |

Verdict: APPROVE — no outstanding source findings; final full suite passed. Hardware and visual checks above remain validation limits, not claims established by unit tests.
