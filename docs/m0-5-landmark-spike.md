# M0-5: Vision Landmark Latency Spike — Results

**Date**: 2026-08-09
**Status**: CONDITIONAL GO

---

## Executive Summary

Vision body-pose + hand-pose + face-mesh ran in **8.3 ms combined mean** on the
macOS/simulator benchmark harness (Apple Silicon CPU, no Neural Engine). That is
far under the 150 ms Tier-0.5 budget. On a real iOS device the Apple Neural Engine
handles these requests and should be as fast or faster. On-device validation is
required before the M2 feature spec is locked, but the spike does not surface any
blocker; M2/M3 planning may proceed.

---

## Measurements (Simulator / macOS CPU proxy)

| Model | Mean (ms) | p95 (ms) | Max (ms) |
|-------|----------:|----------:|---------:|
| Body Pose (`VNDetectHumanBodyPoseRequest`) | 4.1 | 4.2 | 4.2 |
| Hand Pose (`VNDetectHumanHandPoseRequest`) | 1.8 | 1.8 | 1.8 |
| Face Mesh (`VNDetectFaceLandmarksRequest`) | 2.7 | 2.8 | 3.6 |
| Combined (all three sequential) | **8.3** | **10.0** | **10.5** |

*Methodology: 1280 × 720 synthetic BGRA pixel buffer; 5 warmup iterations discarded;
30 measured iterations; macOS swiftc -O build; Apple Silicon (M-series) host CPU.*

**Important caveats:**

1. **No Neural Engine**: The iOS simulator does not expose the device's ANE. These
   timings reflect the macOS CPU path. On-device, Vision hands the workload to the
   Neural Engine, which is typically faster.
2. **No real camera frames**: The simulator camera API is unavailable, so the
   `VisionLandmarkProbe` pipeline was not exercised end-to-end. The measurements
   are a direct Vision API call against a synthetic pixel buffer.
3. **Blank frame bias**: All three requests run against a grey, featureless frame.
   Body-pose on a real image with a subject may take slightly longer; face-mesh
   will also do bbox detection first.

---

## On-Device Validation Required

Run the following on a physical iPhone 16 (or later) with the debug overlay open:

1. Point the camera at a person (all three detectors will have real subjects).
2. Let the app run for at least 3–5 minutes to accumulate warm p95 numbers and
   trigger thermal events.
3. Read the **Body / Hand / Face / VisionTotal** rows from the debug overlay.

### Pass / Fail Criteria

| Result | Combined p95 | Decision |
|--------|:-------------|:---------|
| GREEN  | < 50 ms     | Run all three on every settled frame at 30 fps cadence. |
| YELLOW | 50–150 ms   | Reduce cadence: landmarks on settled frames only, ≤ 5 fps. |
| RED    | > 150 ms    | Drop one model for v1; re-evaluate cadence before M2 start. |

---

## Fallback Strategy (if device fails budget)

1. **Lower resolution**: Drop input to 640 × 480 before passing to Vision.
   Expected speedup: ~2×.
2. **Reduce cadence**: Run landmarks only on "settled" frames (blur score below
   threshold, FPS stable); gate to at most 5 fps regardless of frame rate.
3. **Drop face mesh**: Body + hand only. `VNDetectFaceRectanglesRequest` is
   an order of magnitude cheaper if rough face bbox is all that's needed.
4. **Pipeline requests through a single handler**: Switch to a single
   `VNImageRequestHandler.perform([body, hand, face])` call so Vision can share
   preprocessing overhead across all three requests (current implementation uses
   separate handlers for isolated per-model timing; a unified handler is a future
   optimization).
5. **Async offload**: Move Vision off the main pipeline entirely; accept up to one
   analysis result per second and overlay it onto subsequent frames.

---

## Decision

**CONDITIONAL GO.** The macOS CPU proxy shows combined latency of 8.3 ms mean /
10.0 ms p95, 18× under the 150 ms budget. This is a strong positive signal. The
actual iOS Neural Engine path will be at minimum comparable, and likely faster.

M2/M3 planning may begin with a default architecture of "all three models on every
settled frame." Before committing to that in the M2 tech spec, a 5-minute sustained
run on a physical iPhone 16 must confirm combined p95 < 150 ms and stable thermal
state. If the device result is YELLOW, switch to 5-fps cadenced landmarks. If RED
(unlikely given proxy data), re-evaluate at M2 kickoff.
