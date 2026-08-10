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

- [ ] M1-1: Tilt signal
- [ ] M1-2: Blur/shake signal
- [ ] M1-3: Exposure/clipping signal
- [ ] M1-4: Framing signal (saliency vs. thirds)
- [ ] M1-5: Cue engine
- [ ] M1-6: Visual guides overlay
- [ ] M1-7: Voice output (TTS + pacing)
- [ ] M1-8: Event-driven sampling + scene-change signature
- [ ] M1-9: Integration & demo build

## Minor findings to surface at final review

- M0-1: `picpal/` directory name should match `PicPal/` in project.yml for case-sensitive FS compatibility (CI on Linux would break). Fix: rename dir or update project.yml to lowercase.
- M0-1: `stop()` is a no-op during `.starting` state — no cancellation path if stop is called before session finishes starting. At minimum, add `cancellationRequested` flag checked before `captureSession.startRunning()`.
- M0-3: `MotionDelegateBox` uses `NSLock` while the rest of the subsystem uses `OSAllocatedUnfairLock` — inconsistency, no correctness issue.
- M0-3: `maxConcurrentOperationCount = 1` in `MotionManager` is a bare literal rather than a named constant — minor constraint violation.
- M0-4: Magic literals `1_000_000_000_000_000` and `1_000_000_000_000_000_000` (attosecond conversions) in `FrameTimer.swift` and `PipelineTelemetryBridge.swift` — should be named constants.
- M0-3: `MotionProcessorTests.swift` line ~131 — `c!` force-unwrap in test code (`settleChangesAtMostOncePerTransition`); safe in practice but will crash test process if assertion above ever fails.
