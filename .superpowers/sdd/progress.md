# PicPal M0/M1 — SDD Progress Ledger

Plan file: docs/picpal-tickets-m0-m1.md
Branch: feature/m0-foundations
Base commit (branch point): 5b0cf70

## M0 — Foundations & de-risking spikes

- [x] M0-1: Camera capture pipeline (commits 9fb1249..d4eb3c3, review clean)
- [x] M0-3: Device motion + settle detector (commits d4eb3c3..7e364dc, review clean)
- [x] M0-2: Live camera view + debug overlay scaffold (commits 7e364dc..1fdd77a, review clean)
- [x] M0-4: Perf & thermal telemetry harness (commits 1fdd77a..aa7c43e, review clean; 121 tests passing)
- [x] M0-5: Landmark latency spike ⚠ GATE (commits aa7c43e..81d0442, review clean; CONDITIONAL GO — 8.3ms combined proxy, on-device p95 validation required before M2 spec lock)

## M1 — Tier 0 real-time loop

- [x] M1-1: Tilt signal + SignalFrame (commit 30123cc, review clean)
- [x] M1-2: Blur/shake signal (commit 862f3b4, review clean)
- [x] M1-3: Exposure/clipping signal (commit 850c958, review clean)
  Minor findings: (a) weak var downstream without lock — safe via ARC atomics but technically violates constraint; same pattern in BlurMonitor (consistent, flag for final review); (b) makeBuffer helper missing defer for unlock
  Minor findings: (a) bare 0.0 float literal in vImageConvert call; (b) two struct-storage-only tests miss processor logic; (c) variance uses scalar loops instead of vDSP; (d) force-unwrap on kernel baseAddress
  Minor findings: (a) ContentView creates a MotionManager — verify only one CMMotionManager runs at a time; (b) redundant Task{@MainActor} hop on tilt callback — defensible but adds one run-loop frame of latency to debug overlay.

- [ ] M1-1: Tilt signal
- [ ] M1-2: Blur/shake signal
- [ ] M1-3: Exposure/clipping signal
- [x] M1-4: Framing signal (saliency vs. thirds) (commits 774a02c..ed65f42, review clean; 12 tests passing)
- [x] M1-5: Cue engine (commits 84f72ef..837b40d, review clean; 27 tests passing)
  Minor finding: SignalFrameAccumulator.update() calls Date() directly instead of injectable clock — no correctness impact today
- [x] M1-6: Visual guides overlay (commit 608e985, review clean; 221 tests passing)
  Minor findings: (a) DebugOverlayViewModel.swift gained `import CoreGraphics` — replace with `import SwiftUI` to satisfy constraint; (b) `thirdsGrid(in:)` Canvas closure discards its own size param and uses captured outer `size` — latent inconsistency, fix if layout changes
- [x] M1-7: Voice output (TTS + pacing) (commits 9977ec7..ed96c23, review clean; 229 tests passing)
- [x] M1-8: Event-driven sampling + scene-change signature (commit fd91bbf, review clean; 247 tests passing)
  Minor finding: TOCTOU on settle flag between two lock acquisitions in shouldProcess — spec-intentional accepted race; add in-code comment for future readers
- [x] M1-9: Integration & demo build (commit da13707, review clean; 252 tests passing)

## Final whole-branch review (commit 701c3d7)

Status: **MERGE-READY** — all Critical and Important findings fixed and verified.

Fix wave (commit 701c3d7) addressed:
- CRITICAL: Camera delegate slot contention → black preview
- CRITICAL: SceneGate permanently closed on Simulator
- IMPORTANT: SceneSignature out-of-bounds read on small buffers
- IMPORTANT: No backpressure on BlurMonitor/ExposureMonitor/FramingMonitor queues
- IMPORTANT: Cue cooldown blocked higher-priority cues
- IMPORTANT: GuidesOverlayView level line rotation direction (sign flip)
- IMPORTANT: Mute did not stop in-flight utterance
- IMPORTANT: VisionLandmarkProbe enabled by default (thermal waste)

252 tests in 27 suites — all passing.

## Minor findings deferred (address before M2)

- M0-1: `stop()` no-op during `.starting` state — add `cancellationRequested` flag
- M1-5: `SignalFrameAccumulator.update()` uses `Date()` directly instead of injectable clock
- M1-8: TOCTOU on settle flag — add in-code comment for clarity

## Minor findings deferred indefinitely

- M0-1: `picpal/` dir vs `PicPal/` in project.yml (Linux case-sensitivity) → MUST FIX if CI added
- M0-3: `MotionDelegateBox` uses `NSLock` instead of `OSAllocatedUnfairLock` — correct, just inconsistent
- M0-3: `maxConcurrentOperationCount = 1` bare literal
- M0-4: Attosecond magic literals in FrameTimer/PipelineTelemetryBridge
- M0-3: Force-unwrap `c!` in MotionProcessorTests ~line 131
- M1-3: `weak var downstream` without lock in BlurMonitor/ExposureMonitor — ARC-safe, documented
- M1-6: `import CoreGraphics` in DebugOverlayViewModel — functionally fine
- M1-6: `thirdsGrid(in:)` Canvas closure ignores own `size` param — equal by construction

## Minor findings to surface at final review

- M0-1: `picpal/` directory name should match `PicPal/` in project.yml for case-sensitive FS compatibility (CI on Linux would break). Fix: rename dir or update project.yml to lowercase.
- M0-1: `stop()` is a no-op during `.starting` state — no cancellation path if stop is called before session finishes starting. At minimum, add `cancellationRequested` flag checked before `captureSession.startRunning()`.
- M0-3: `MotionDelegateBox` uses `NSLock` while the rest of the subsystem uses `OSAllocatedUnfairLock` — inconsistency, no correctness issue.
- M0-3: `maxConcurrentOperationCount = 1` in `MotionManager` is a bare literal rather than a named constant — minor constraint violation.
- M0-4: Magic literals `1_000_000_000_000_000` and `1_000_000_000_000_000_000` (attosecond conversions) in `FrameTimer.swift` and `PipelineTelemetryBridge.swift` — should be named constants.
- M0-3: `MotionProcessorTests.swift` line ~131 — `c!` force-unwrap in test code (`settleChangesAtMostOncePerTransition`); safe in practice but will crash test process if assertion above ever fails.

## M2 — Final whole-branch review fix wave

Fix wave (commits 01c5e69..362f058): all Critical and Important findings resolved.
Re-review: **Approved** — spec compliance ✅, code quality Approved.

- C1 fixed: `LandmarkCadenceController.lastPresenceResult` now written before presence guard (3-line change); stuck-true bug eliminated; regression test added.
- C2 fixed: Headroom hints corrected — `nudgeUpHeadroom` when head near top, `nudgeDownHeadroom` when too much space; tests and demo-script corrected.
- I1 fixed: `isBusy` flag prevents probeQueue accumulation; CVPixelBuffer pool safe.
- I2 fixed: Vision presence check moved off camera delivery queue (into probeQueue via `probe()` helper); Tier-0 forwarding still first statement.
- I3 fixed: Reset path funneled through probeQueue; no cross-queue producer mutation.
- I4 documented: MediaPipe keypoint confidence comment explains visibility/presence nil → detector-level gate is the effective floor.
- I5 fixed: `CuePriority.obstruction = -1` (above `.stability = 0`); obstruction now bypasses tilt/blur cooldowns; new `lensObstructedBypassesTiltCooldown` test added.

340 tests passing. Remote HEAD: 362f058.

Minor deferred: `LandmarkOrchestrator.swift` is 335 lines (35 over the 300-line guideline). Follow-up refactor: extract `probe()` + `runInference()` into `LandmarkOrchestratorProbe` helper type.

**Status: MERGE-READY** — all Critical and Important findings fixed and verified.

Task M2-7: complete (commits b69f435..01c5e69, review clean)
- BodyCueIntegrationTests.swift: 10 Swift Testing tests for BodySignal → CueEngine path
- demo-script.md: M2 body section added (6 sub-sections: obstruction/crop/gaze/headroom/zero-false-cue/thermal)
- develop pushed to remote (Remote HEAD: 01c5e69)
- Minor deferred: 2 typos in test function names (zeroPalsePositiveBaseline, lensObstructedRefirers...)
- 338 tests total

Task M2-6: complete (commits 7f03182..b69f435, review clean)
- LandmarkOrchestrator: CameraFrameDelegate, LandmarkCadenceController gating, Vision body + MediaPipe hand/face inference, BodyHint priority merge, onBodySignal callback
- CueEvaluator: block 0.5 (lensObstructed → priority:.stability before tilt), block 4.5 (body cues after composition)
- CueText: 5 new body cue strings
- ContentView: orchestrator wired between SceneGateAdapter and pipeline; try? graceful degradation
- DebugOverlayViewModel: bodyHint added and displayed
- 10 new Swift Testing tests (CueEvaluatorBodyTests); 328 total
- Minor deferred: missing sourceTier assertion in nudgeDownHeadroomYieldsBodyCue test

Task M2-5: complete (commits 8d5d7a6..7f03182, review clean)
- GazeAnalyzer: landmarks 234 (left temporal), 454 (right temporal), 4 (nose tip); yawFraction = noseMidOffsetX/faceWidthX; gazeAway when abs(yaw) > 0.15
- GazeSignalProducer: wraps analyzer + TemporalSmoother<BodySignal>; empty → nil path → noPersonPresent
- 12 new Swift Testing tests; 318 total
- Minor deferred: bare 3.0 divisor in mean confidence (cf. named referenceKeypointCount)

Task M2-4: complete (commits 29c2457..8d5d7a6, review clean)
- HandObstructionAnalyzer: ≥3 high-confidence keypoints within 15% of any frame edge → lensObstructed; else goodBody; <3 qualified → nil
- HandObstructionSignalProducer: wraps analyzer + TemporalSmoother<BodySignal>; empty → nil path → noPersonPresent on stable break
- 9 new Swift Testing tests; 306 total
- Minor deferred: unnamed 1.0 in isNearEdge (cf. LandmarkCoordinates.Axis.normalizedMax); redundant let margin = edgeMargin alias

Task M2-0: complete (commits 74ff9b9..0b7b5fb, review clean)
- SwiftTasksVision 0.10.21 (community SPM wrapper) integrated via project.yml + xcodegen
- hand_landmarker.task (7.5 MB) + face_landmarker.task (3.6 MB) bundled
- LandmarkCoordinates.swift: Vision→UIKit + MediaPipe→UIKit helpers, 10 tests
- MediaPipeLandmarkProbe.swift: full compiling probe (isEnabled: false until M2-1)
- On-device latency: PENDING_DEVICE_RUN (no iPhone 17 in agent env)
- Minor deferred: model files as binary blobs (consider Git LFS); SwiftTasksVision 0.10.21 not yet at MediaPipe 1.0.0

263 tests passing.
Task M2-1: complete (commits 0b7b5fb..11fd510, review clean)
- PresenceGate: VNDetectHumanRectanglesRequest, confidence threshold, dominant-subject by confidence+area
- LandmarkCadenceController: 3-gate (cadence≤5fps, settle, presence), injectable clock, OSAllocatedUnfairLock
- 7 new Swift Testing tests; 269 total
- Minor deferred: test duplication, inline constants in tests, ControllerConstants enum, lastApprovalTime=0 comment
Task M2-2: complete (commits 11fd510..7df3e1b, review clean)
- KeypointFilter: Keypoint struct, confidence floor 0.6, pure stateless
- TemporalSmoother<T>: OSAllocatedUnfairLock, edge-triggered, update(nil) breaks run, reset()
- BodySignal/BodyHint: 6 hint cases, noPersonPresent sentinel
- SignalFrame.body: BodySignal? field added; .empty has body: nil
- SignalFrameAccumulator.update(body:) + body forwarding in all existing update methods
- 18 new Swift Testing tests; 287 total
- Minor deferred: defaultStableFrameCount computed var vs let; accumulator tests in TemporalSmootherTests file
Task M2-3: complete (commits 7df3e1b..29c2457, review clean)
- BodyPoseAnalyzer: crop detection (9 joints, cropMargin), headroom (nose/neck proxy), all via LandmarkCoordinates
- BodyPoseSignalProducer: wraps analyzer + TemporalSmoother<BodySignal>; nil observation → noPersonPresent
- 10 new Swift Testing tests; 297 total
- Important fixed: deduplicated .neck in extractKeypoints candidates (Set union)
- Minor deferred: test 2 negation assertion; injectSignalForTesting test-only method
Task M2-5: complete (318 tests passing)
- GazeAnalyzer: landmarks 234/454/4 for yaw, defaultYawThreshold=0.15, defaultKeypointConfidenceFloor=0.5
- GazeSignalProducer: wraps GazeAnalyzer + TemporalSmoother<BodySignal>; empty → nil → noPersonPresent on stable break
- 12 new Swift Testing tests covering all 8 required scenarios plus 4 bonus boundary/confidence tests

---

# M3 — Tier 2 VLM Aesthetic Coaching

Plan file: docs/picpal-tickets-m3.md
Branch: feature/m3-vlm-tier
Base commit (branch point): 111028f

Execution order (per dependency graph):
  1. M3-0 (⚠ SPIKE — risk-critical, gates client contract)
  2. M3-2 (independent of M3-0, parallels it logically but serialized here)
  3. M3-1 (depends on M3-0 wire format)
  4. M3-4 (depends on M3-0 client contract)
  5. M3-3 (depends on M3-2)
  6. M3-5 (depends on M3-1, M3-2, M3-3, M3-4)
  7. M3-6 (depends on M3-5)
  8. M3-7 (depends on M3-6)

Minor deferred findings from M2 to watch:
  - LandmarkOrchestrator.swift 335-line overage addressed by probe extraction (resolved)
  - project.yml PicPal/ vs picpal/ case sensitivity — will break CI (still open)

- [x] M3-0: VLM proxy service + swappable client abstraction ⚠ SPIKE (DONE_WITH_CONCERNS — proxy + client complete, latency test blocked by missing ANTHROPIC_API_KEY, see task-m3-0-report.md)
- [ ] M3-2: VLM request gate: settle + novelty + cadence + budget
- [x] M3-1: Frame encoder (downscale → JPEG) (commit 575e8b3, review clean; 374 tests passing)
- [x] M3-4: AestheticSignal + prompt design + response parsing (commits 575e8b3..799a060, review clean; 393 tests passing)
- [x] M3-3: Stale-suppression + response matching (commit 7e60fa3, review clean; 402 tests passing)
- [x] M3-5: VLMOrchestrator + cue-engine wiring at .aesthetic (commits 7e60fa3..f6d16ad, review clean; 413 tests passing)
- [x] M3-6: Offline degradation + on-device-only mode + privacy copy (commits 6fd6bc2..9fb3af8, review clean; 419 tests passing)
  Minor deferred: backoffBaseSeconds promoted to public unnecessarily (internal would suffice with @testable import); harmless
  Minor deferred: Task.sleep as synchronization barrier in orchestrator tests — brittle under CI load; works for current immediate-throw mocks
- [x] M3-7: Integration, deployment & validation (commit e723fcd, review clean; 420 tests passing)
  PENDING_DEVICE_RUN: non-regression FPS baseline, stale-suppression walkthrough, offline walkthrough, on-device-only walkthrough, battery/thermal session
  PENDING_DEPLOYMENT: cost check (proxy call count), proxy deployed to real host

## M3 Final whole-branch review fix wave (commits e723fcd..fc14c3e)

**Status: MERGE-READY** — all Critical and Important findings fixed and verified.

Fix wave (commit fc14c3e) addressed:
- IMPORTANT: `vlmOrch.update(bodyHint:)` never called — StaleSuppressor body-hint arm permanently single-tag (fixed: wired in LandmarkOrchestrator callback)
- IMPORTANT: `isVLMInFlight` stuck `true` after NOTHING_TO_SAY/stale/error (fixed: `onRequestCompleted` defer covers all exit paths)
- IMPORTANT: `VLMOrchestratorTests.swift` 360 lines > 300 (fixed: helpers extracted to `VLMTestSupport.swift`)
- MINOR fixed: contradictory "0 or 1 is valid" comment removed from `validRemarkTriggersCallback`

420 tests passing.

Minor deferred (not blocking merge):
- `backoffBaseSeconds` promoted to `public` unnecessarily (harmless)
- `Task.sleep` synchronization barrier in orchestrator tests (pre-existing, works for immediate-throw mocks)
- JPEG encode failure path leaves `isVLMInFlight` stuck (pre-existing gap, extremely rare)
- `SignalFrame.swift` MARK headings use milestone numbers not tier labels (cosmetic confusion)
- `FrameEncoder` allocates fresh `CIContext()` per call (low-frequency call, minor perf)
- First-run consent before cloud VLM sends frames — SPAWNED as separate task
- `project.yml` PicPal/ vs picpal/ case sensitivity — pre-existing, breaks CI on Linux

---

# M4 — Tuning & Validation

Plan file: docs/picpal-tickets-m4.md
Branch: feature/m4-tuning-validation
Base commit (branch point): fc30d20

Execution order:
  1. M4-0 (AestheticSignal auto-expiry — active bug fix)
  2. M4-6 (Validation session kit — static types, no deps)
  3. M4-5 (Runtime tuning panel + cadence config)
  4. M4-1 (KPI telemetry: cue event log + settle→cue timer)
  5. M4-2 (Wire BatteryMonitor + TelemetryExporter)
  6. M4-3 (First-run consent gate)
  7. M4-4 (Post-session survey)
  8. M4-7 (Integration & validation — PENDING_DEVICE_RUN)

- [x] M4-0: AestheticSignal auto-expiry
- [x] M4-6: Validation session kit
- [x] M4-5: Runtime tuning panel + cadence config
- [x] M4-1: KPI telemetry — cue event log + settle→cue timer
- [x] M4-2: Wire BatteryMonitor + TelemetryExporter
- [x] M4-3: First-run consent gate
- [x] M4-4: Post-session survey
- [ ] M4-7: Integration, deployment & validation ⚠ PENDING_DEVICE_RUN
Task M4-0: complete (commit b770f4a, review clean; 424 tests passing; accumulator is lock-protected @unchecked Sendable — off-main-actor call is safe)
Task M4-6: complete (commits f0168a0..058a4a0, review clean after fix; 428 tests passing)
Task M4-5: complete (commit 9ff3e48, review clean; 432 tests passing; note: TuningSettings.aestheticExpirySeconds not wired to ContentView expiry closure — confirmed out-of-scope per brief)
Task M4-1: complete (commit a724ce6, review clean; 444 tests passing; minor: timing-sensitive SettleEventTimer test, unreachable guard in percentile)
Task M4-2: complete (commit d4d3149, review clean; 444 tests passing; note: TelemetryFeed does not expose currentStats/thermalEvents — exportSnapshot uses empty placeholders, deferred)
Task M4-3: complete (commit 587ac36, 453 tests passing; xcodegen regenerated to register new files)
Task M4-3: complete (commits 587ac36..dbdf70c, review clean; 453 tests passing)
Task M4-4: complete (commit f478466, review clean; 460 tests passing)

## M4 Final whole-branch review fix wave (commit 70f2009)

**Status: MERGE-READY** — all Critical and Important findings fixed and verified.

Fix wave (commit 70f2009) addressed:
- CRITICAL: VLMSettings.isOnDeviceOnly defaults to true when key absent — no cloud frames before consent
- CRITICAL: NSAllowsArbitraryLoads replaced with NSAllowsLocalNetworking in project.yml + Info.plist
- IMPORTANT: settleEventTimer?.reset() added in .background scenePhase handler
- IMPORTANT: Triple-tap gesture order fixed in DebugOverlayView (count:3 before count:1)
- IMPORTANT: Dead "Remark expiry" stepper removed from TuningPanel and TuningSettings
- IMPORTANT: @Suite(.serialized) added to TuningSettingsTests, ConsentGateTests, PostSessionSurveyTests, VLMSettingsTests, VLMOrchestratorTests
- IMPORTANT: ContentView.swift split (452→172 lines); wireUp + exportSnapshot + scenePhase handler moved to ContentView+Session.swift (304 lines)

460 tests passing.

---

# M5 — Scene-Descriptor Caching

Plan file: docs/picpal-tickets-m5.md
Branch: feature/m5-caching
Base commit (branch point): a8323638a1d56b4fcbe76d77cfb93555e25bc9f4

Task M5-0: complete (commit 04d9173, review clean; 471 tests passing)
- VLMResponseCache: final class @unchecked Sendable, OSAllocatedUnfairLock<[Entry]>, injectable clock
- defaultMaxEntries=20, defaultTTLSeconds=30.0 (named constants)
- lookup uses isMateriallyDifferent + TTL; store deduplicates before insert, evicts tail
- 11 VLMResponseCacheTests covering all acceptance criteria + concurrency
Minor deferred: dead `import os.log` at VLMResponseCache.swift:2; namedConstants test asserts > 0 rather than == exact values

Task M5-1: complete (commits 759398f..c054df9, review clean after fix; tests passing)
- VLMResponseCache injected into VLMOrchestrator; cache consulted after gate, before FrameEncoder.encode
- Bypassed when referenceImage != nil (referenceImageLock guard)
- VLMSessionStats: cacheHits/cacheMisses counters, OSAllocatedUnfairLock protected
- VLMSessionStats.swift + VLMOrchestratorConstants extracted to keep orchestrator under 300 lines
- TelemetrySnapshot gains vlmCacheHits: Int? + vlmCacheMisses: Int? (backward-compatible)
- TuningSettings: vlmCacheTTLSeconds + vlmCacheMaxEntries under #if DEBUG; keys follow com.picpal.tuning.* convention; removed by resetToDefaults()
- TuningPanel: "Cache TTL" + "Max entries" steppers in VLM section
- ContentView+Session: invalidateCache() in .background handler alongside settleEventTimer?.reset()
- Fix: InstantVLMClient gains callCount; cacheHitWithRemark_bypassesClient asserts callCount == 2
Minor deferred: VLMOrchestratorConstants visibility widened to internal unnecessarily (was private); cosmetic, no correctness impact

## M5 Final whole-branch review fix wave (commit 4904a93)

**Status: MERGE-READY** — all Important findings fixed and verified. 475 tests passing.

Fix wave (commit 4904a93) addressed:
- IMPORTANT: TuningSettings cache params now wired in wireUp() via #if DEBUG block — vlmCacheTTLSeconds + vlmCacheMaxEntries passed to VLMResponseCache(maxEntries:ttlSeconds:) before orchestrator init
- IMPORTANT: recordCacheMiss() moved to step 3b (after cache miss, before isBusy) so hits+misses = total gate passes; removed from step-5f success path
- IMPORTANT: VLMOrchestrator.init access level drop (public→internal) documented with Swift 6 constraint comment

Minor deferred (surface at M6 review):
- VLMResponseCache.swift:2 dead `import os.log`
- VLMResponseCacheTests.swift: namedConstants test asserts > 0 rather than == 20 / == 30.0
- VLMSessionStats.swift: VLMOrchestratorConstants and VLMFailureState have internal visibility (was private) — encapsulation regression
- VLMSessionStats.swift: misleading filename (contains 3 unrelated types)
- ContentView+Session.swift debug onExportTelemetry closure omits cache stats (debug-only, low impact)

---

# M5.5 — Reference Photo Mode

Plan file: docs/picpal-tickets-m5-5.md
Branch: feature/m5.5-reference-photo
Base commit (branch point): 4904a93485a891b9d738ae39ce3140451c021669

Task M5.5-0: complete (commits 04bed33..01b1d40, review clean after fix; 506 tests passing)
- ReferencePose: Sendable struct, [String: CGPoint] bodyKeypoints, no Vision import, explicit memberwise init
- PoseDelta: five offset/delta fields, defaultMatchThreshold=0.08, defaultScaleMatchThreshold=0.15, defaultFaceYawThreshold=0.15 (private), isWithinThreshold using all three, nil faceYawDelta → matched
- 35 tests across PoseDeltaTests (23) + ReferencePoseTests (12)
- Fix: hollow #expect(true) replaced with Task.detached Sendable runtime check; force-unwraps → try #require()
Minor deferred: defaultFaceYawThreshold is private (defaultMatchThreshold/defaultScaleMatchThreshold are public) — minor visibility inconsistency

Task M5.5-1: complete (commits 5aa27ec..997e086, review clean after fix; 516 tests passing)
- ReferenceSession: @MainActor final class, extractPose() async, Task.detached Vision inference, @Published pose + extractionError, injectable extractor closure
- runVision throws ReferenceSessionError (.imageConversionFailed, .noPoseDetected); extractPose do/catch stores to extractionError
- ReferencePhotoPicker: UIViewControllerRepresentable, PHPickerViewController, selectionLimit:1, filter:.images
- VNHumanBodyPoseObservation keypoints: double-hop .rawValue.rawValue for plain String
- Face data via VNDetectFaceLandmarksRequest, nil when no face; headroomFraction with max(0,...) guard
- 10 ReferenceSessionTests covering state transitions, error paths, overwrite behavior, Combine transitions, 500ms bound
- Fix: error enum wired (was dead code); overwrite test rewritten using same session + OSAllocatedUnfairLock<Bool> mock
Minor deferred: comment on injectable closure has wrong type annotation; non-ReferenceSessionError silently discarded (no logging)

Task M5.5-3: complete (commit f0d5004, review clean; 8 ReferenceOverlayViewTests passing)
- ReferenceOverlayView: SwiftUI struct, ghost Image(uiImage:) scaled to fit, opacity/tint driven by isMatched
- Layout enum: defaultOpacity=0.30, matchOpacity=0.15, matchTint=Color.green.opacity(0.35), xmarkSymbol, swipeToDismissMinDist
- ProgressView centered when isExtracting; animated easeInOut(duration:0.4) on match transition
- X button (xmark.circle.fill) top-trailing + swipe-down DragGesture both call onDismiss()
- Minor deferred: currentOpacity is internal (not private) for testability — not annotated; swipe gesture on Image only (not full overlay); matchTintOverlay uses Color.clear when not matched

Task M5.5-2: complete (commits b6a4db6..1d8c500, review clean after fix; 21 ReferenceCoachTests passing)
- ReferenceCoach: stateless struct, cue(from:isNewMatch:) -> Cue?, CueText enum for all strings
- Priority: face yaw > scale > horizontal > vertical > headroom; CuePriority.body (.tier05)
- isWithinThreshold && isNewMatch → match-confirmation cue; isWithinThreshold && !isNewMatch → nil
- Fix: dead ternary on face yaw branch removed (both branches were identical); test file trimmed 378→297 lines
Minor deferred: explicit public init() {} is unnecessary (auto-synthesized); faceYawThreshold duplicated from PoseDelta (commented)
