# Cloud scheduling and measurement contract

The development proxy's limits and reset procedure are documented in [proxy/README.md](../proxy/README.md).

## Scheduling

Generic cache delivery observes the same cadence and scene novelty as live delivery but never spends network quota. Each actual client attempt, including retries, consumes one of the 50 session calls immediately before transport. Encoding failure and queued context cancellation consume none. Reference requests remain single-flight and share the eight-second new-analysis dispatch cadence with generic work. The existing bounded generic transport retries are an explicit exception: up to two retries use one-second then two-second backoff and each consumes another budget unit. Reference requests have no automatic transport retry.

A consented reference starts profile preparation immediately without waiting for a camera frame or settled motion. Profiles send only the reference JPEG and have a ten-second service timeout; camera motion and live evidence age do not invalidate them. Context replacement, geometry revision, consent revocation, and on-device-only mode still invalidate their result. Comparison evidence keeps its strict eight-second age limit and settled-motion requirement. A reference JPEG is retained in memory for the consented context, reused across comparisons/geometry changes, and cleared on replacement or consent revocation.

While auto capture is armed, the composition root sends `CameraScreenModel.isArmed` to the orchestrator. Reference renewal is eligible at eight seconds when settled. Disarming restores the ordinary twenty-second idle refresh. Scene changes and explicit verification can also request comparison at the next permitted time. Armed renewal approaches **7.5 calls/minute**, so the previous three-calls/minute figure is an idle target, not a hard cap. The 50-call client and 200-call persistent proxy ceilings remain enforced. Nonzero response latency still creates gaps in eight-second evidence coverage; this change does not promise continuous readiness.

## Snapshot API

`VLMOrchestrator.sessionStats` is a thread-safe, public, `Codable` value snapshot. It contains cache hits/misses, network attempt count, accepted results, stale discards, and the most recent 128 request records. An orchestrator represents one session; constructing a new orchestrator resets counters. Records contain only metadata: UUID, operation, captured/preparation time, first dispatch time, asynchronous completion time, encoding seconds, cache-hit flag, attempts, and outcome. No images, prompts, or credentials are retained in telemetry.

For example, debugging/export tooling can encode `try JSONEncoder().encode(orchestrator.sessionStats)`. These records measure completion only after the awaited client response and result validation; synchronous frame callback return is not completion. `completionLatency` is completed minus captured/preparation time. Per-attempt network duration can be approximated only for a single-attempt record; retry records include intervening retry delays.

The injected orchestrator clock uses Unix seconds in production. Camera timestamps use the AVFoundation host clock: arrival translates host-clock age to that Unix clock once. Invalid/zero timestamps are recorded as unknown (`nil`), not fabricated. Profile time marks preparation start, not the historical time the reference photo was taken. Clock changes can affect wall-clock durations; negative durations are clamped to zero.

The existing bridge and debug overlay now explicitly label **scene-gated frames/s** and **synchronous dispatch** duration. Bridge timing does not measure capture FPS, asynchronous Vision/cloud inference, or sensor-to-caption latency. The legacy export `frameStats` retains its field name for compatibility and has the same synchronous-dispatch interpretation.

## Remaining measurements

Physical-device profiling is still needed for local/diagnostic duplicate work, observation age, dropped analysis, thermal load, battery, speech completion and Photos saving. The capture/save transaction is unchanged. Simulator and mocked-proxy tests prove accounting, scheduling and resource bounds; they do not measure real-service latency or device throughput.
