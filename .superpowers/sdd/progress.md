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
