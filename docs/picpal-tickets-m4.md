# PicPal — M4 Tickets (Tuning & Validation)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [picpal-prd.md](picpal-prd.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6) + Node proxy
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: Hit the KPIs, not just the features. Moderated sessions produce measurable data for the primary KPI ("feels real-time" ≥70%) and non-annoyance band (~1–3 cues/stable episode). Every task in M4-0 through M4-6 is codeable without a device; M4-7 is the validation run itself and is PENDING_DEVICE_RUN.

## Locked decisions (2026-08-11)

1. **Cadence starting point: 8s** — VLMRequestGate defaults to 8s, configurable at runtime via TuningSettings. The PRD's "2–4s" is the tuning *target* to evaluate against the non-annoyance band, not the starting value. Rationale: 8s is the conservative safe default; a tuning panel lets us drive it down without rebuilds and measure the effect on KPIs.
2. **AestheticSignal auto-expiry: `minRepeatIntervalSeconds + 1.0`** — remarks auto-clear from SignalFrame after this delay. Active bug in M3 head: old remarks re-fire every 5s indefinitely.
3. **No AestheticSignal type changes** — expiry is wired at the ContentView layer via a Task cancel/reschedule pattern, not via a new field on AestheticSignal or CueEvaluator.
4. **TelemetrySnapshot extended for KPI** — `CueTelemetryReport` and `surveyResponse` added. The existing JSON filename format is preserved; the schema gains new optional fields.
5. **Consent gate defaults to on-device-only** — if the user hasn't consented, `isOnDeviceOnly` is temporarily `true` for that session. The permanent UserDefaults preference is only written when the user actively chooses.
6. **TuningPanel is debug-only** — `#if DEBUG` guard, never visible in App Store builds.

## Conventions (carried from M0/M1/M2/M3)

- Swift 6 strict concurrency; `OSAllocatedUnfairLock` for shared mutable state.
- **Swift Testing only** (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- **Tier-0 forwarding invariant**: `downstream?.cameraCapture(...)` is the first statement in every `CameraFrameDelegate` method. Non-negotiable.
- Immutable value snapshots — new types are `struct` with `Sendable + Encodable` unless identity semantics are required.

## Execution order

```
M4-0 (active bug fix, no deps)
  ↓
M4-6 (static types, no deps — can run in parallel with M4-0)
  ↓
M4-5 (TuningSettings singleton, gates M4-2 cadence config)
  ↓
M4-1 (KPI telemetry callbacks into CueEngine)
  ↓
M4-2 (wire BatteryMonitor + TelemetryExporter, consumes CueTelemetryReport from M4-1)
  ↓
M4-3 (consent gate — relatively independent, insert after M4-2)
  ↓
M4-4 (post-session survey, needs session lifecycle from M4-2/M4-3 wiring)
  ↓
M4-7 (PENDING_DEVICE_RUN — validation sessions)
```

---

## M4-0 — AestheticSignal auto-expiry  ⚠ ACTIVE BUG
**Size**: S · **Deps**: none · **Priority**: HIGH

**Problem**: `SignalFrameAccumulator` carries the last-set value for every field in subsequent frames. Once an `AestheticSignal(.remark, ...)` lands, every subsequent `SignalFrame` carries that remark — causing `CueEvaluator` to re-fire it every `minRepeatIntervalSeconds` (5s) indefinitely. The VLM session budget ticks up, the VLM discard count misleads, and the user hears the same coaching remark on repeat until a new VLM response overwrites it.

**Fix approach**: In `ContentView.wireUp()`, the `onAestheticSignal` closure manages a cancellable expiry `Task`. When a remark arrives, it cancels any pending expiry and schedules a new one after `aestheticRemarkExpirySeconds`. When the expiry fires, it calls `accum.update(aesthetic: AestheticSignal(hint: .nothingToSay, remark: ""))` to silence the engine. The Task is also cancelled when `onRequestDispatched` fires (the old remark should not re-fire while a new request is in flight).

**Acceptance criteria**

- [ ] `aestheticRemarkExpirySeconds` is a named constant: `CueEngine.defaultMinRepeatIntervalSeconds + 1.0`.
- [ ] When `onAestheticSignal` fires with `.remark`: cancel any existing expiry Task; schedule a new expiry Task at `aestheticRemarkExpirySeconds`.
- [ ] When the expiry Task fires: call `accum.update(aesthetic: AestheticSignal(hint: .nothingToSay, remark: ""))`. Clear `debugViewModel.aestheticRemark` on the main actor.
- [ ] When `onRequestDispatched` fires: cancel the pending expiry Task (don't expire the old remark while the new one is in flight — let the new remark's arrival start a fresh expiry).
- [ ] No changes to `AestheticSignal`, `CueEvaluator`, `StaleSuppressor`, or `VLMOrchestrator`. The fix lives entirely in `ContentView`.
- [ ] New test in `AestheticSignalLifetimeTests.swift`: drive a remark through `accum` + `CueEngine`, advance the clock past `aestheticRemarkExpirySeconds`, verify `process(frame:)` returns `nil` for aesthetic cues after expiry. Use injectable clock in CueEngine.

---

## M4-1 — KPI telemetry: cue event log + settle→cue timer
**Size**: M · **Deps**: none (adds a callback to CueEngine, no existing interface changes)

**Goal**: Instrument every cue emission with enough data to compute the primary KPIs offline: actionable latency (stable frame → first coaching cue), cue-count distribution by tier, and session-level summary.

**New types** — all in `picpal/Sources/Telemetry/`:

```swift
// CueEvent.swift
struct CueEvent: Sendable, Encodable {
    let timestamp: Date
    let text: String
    let tier: CueTier                      // .tier0 | .tier05 | .tier2
    let latencyFromSettleMs: Double?       // nil if no settle event was recorded for this burst
}

// CueTelemetryReport.swift
struct CueTelemetryReport: Sendable, Encodable {
    let totalCues: Int
    let tier0Count: Int
    let tier05Count: Int
    let tier2Count: Int
    let medianSettleLatencyMs: Double?     // nil if no latency samples
    let p95SettleLatencyMs: Double?        // nil if < 5 samples
    let sessionDurationSeconds: TimeInterval
}
```

**`CueLogger`** — `picpal/Sources/Telemetry/CueLogger.swift`
- `OSAllocatedUnfairLock`-protected, max 500 events (`maxEventCount` named constant).
- `func record(_ event: CueEvent)` — appends, drops oldest when at cap (ring-buffer semantics).
- `func events() -> [CueEvent]` — returns a snapshot.
- `func makeSummary(sessionStart: Date) -> CueTelemetryReport` — computes counts and latency percentiles.
- 100% injectable, no UIKit dependency.

**`SettleEventTimer`** — `picpal/Sources/Telemetry/SettleEventTimer.swift`
- `OSAllocatedUnfairLock`-protected.
- `func recordSettle()` — stamps `Date()`.
- `func latencyMilliseconds(cueAt: Date) -> Double?` — returns ms since last settle, or `nil` if no settle recorded. Clamps negative values (settle after cue) to `nil`.
- `func reset()` — clears the last-settle timestamp (call when scene changes).
- Injectable `clock: @Sendable () -> Date` for testing.

**CueEngine changes**
- Add `onCueEmitted: (@Sendable (CueEvent) -> Void)?` parameter to `init` (default `nil`).
- In `process(frame:)`, after emitting a non-nil cue: call `onCueEmitted?(CueEvent(timestamp: now, text: candidate.text, tier: candidate.sourceTier.asCueTier, latencyFromSettleMs: nil))`. The `latencyFromSettleMs` is `nil` here — it gets populated by the ContentView wrapper before passing to `CueLogger.record`.
- A simpler approach: `onCueEmitted` receives just the `Cue`; the ContentView wrapper computes latency and creates the `CueEvent`. Either is fine — the implementer chooses the cleaner option.

**ContentView wiring**
- Create a `SettleEventTimer` in `wireUp()`.
- When `TiltMonitor` fires `onSettleChange(settled: true)`, call `timer.recordSettle()`.
- In the `SignalFrameAccumulator` callback, after `CueEngine.process(frame:)` returns a non-nil cue, compute `latencyMs = timer.latencyMilliseconds(cueAt: now)`, call `logger.record(CueEvent(...))`, call `timer.reset()`.
- When scene changes (the `SceneSignature`-based gate fires), call `timer.reset()` to invalidate stale settle timestamps.

**Acceptance criteria**

- [ ] `CueLogger`, `CueEvent`, `CueTelemetryReport`, `SettleEventTimer` defined in `Telemetry/`.
- [ ] `CueLogger.maxEventCount = 500` named constant; oldest events dropped when at cap.
- [ ] `CueLogger.makeSummary` returns correct per-tier counts and nil percentiles when no latency data.
- [ ] `SettleEventTimer.latencyMilliseconds` returns nil before any `recordSettle()` call.
- [ ] `SettleEventTimer.latencyMilliseconds` returns nil when cueAt < settle (clamp prevents negative latency).
- [ ] CueEngine `onCueEmitted` callback fires for every non-nil `process(frame:)` return; does not fire on silence.
- [ ] Unit tests: CueLogger ring-buffer behavior (cap enforcement), CueTelemetryReport p95 with 5+ samples, SettleEventTimer edge cases (no settle, negative latency, reset).
- [ ] No changes to `CueEvaluator` or the public `CueEngine.process` signature.

---

## M4-2 — Wire BatteryMonitor + TelemetryExporter
**Size**: M · **Deps**: M4-1 (CueTelemetryReport)

**Goal**: Activate the already-built `BatteryMonitor` and `TelemetryExporter` and extend `TelemetrySnapshot` to carry KPI data. Export is triggered by a debug gesture; the output JSON is the validation artifact for moderated sessions.

**`TelemetrySnapshot` extension** — add two optional fields (backward-compatible):
```swift
public struct TelemetrySnapshot: Sendable, Encodable {
    // ... existing fields ...
    public let cueTelemetry: CueTelemetryReport?     // nil if CueLogger not wired
    public let surveyResponse: Int?                  // 1–5, nil if survey not shown yet
}
```

**ContentView wiring**
- `@State private var batteryMonitor = BatteryMonitor()` — retained.
- `@State private var cueLogger = CueLogger()` — retained; receives events from CueEngine callback.
- `@State private var settleTimer = SettleEventTimer()` — retained.
- `@State private var telemetryExporter: TelemetryExporter?` — created in `wireUp()` via `try? TelemetryExporter.inDocuments()`.
- In `wireUp()`: call `batteryMonitor.startSession()`.
- On app going to background (`.onChange(of: scenePhase)`): call `batteryMonitor.endSession()`, build `TelemetrySnapshot`, call `try? telemetryExporter?.export(snapshot:)`.
- On app returning to foreground: call `batteryMonitor.startSession()` again.

**Export trigger** (debug-only)
- In `DebugOverlayView`: add a triple-tap gesture that calls `exportTelemetry()` — a method injected via the ViewModel.
- `DebugOverlayViewModel` gains `var onExportTelemetry: (() -> Void)?` — called by the triple-tap gesture.
- `ContentView` assigns this in `wireUp()`.

**Acceptance criteria**

- [ ] `TelemetrySnapshot` compiles with the two new optional fields; existing callers (tests) still compile because both fields default to `nil`.
- [ ] `BatteryMonitor.startSession()` called in `wireUp()` and on each foreground transition.
- [ ] `BatteryMonitor.endSession()` called on each background transition; result included in snapshot.
- [ ] Export fires on background AND on triple-tap debug gesture.
- [ ] Exported JSON parses correctly in `jq` (no encoder errors, no missing keys).
- [ ] Export is a no-op (no crash) when `telemetryExporter` is nil (Documents directory unavailable).
- [ ] Unit test: `TelemetrySnapshot` encodes/decodes with all optional fields nil and all populated.

---

## M4-3 — First-run consent gate
**Size**: M · **Deps**: none (independent of M4-1/M4-2)

**Goal**: Before any frame is sent to the cloud VLM, the user must explicitly choose to enable it. This is a privacy requirement (App Store guideline 5.1) and a trust requirement (users who opt in consciously are more likely to forgive false cues during validation).

**Architecture**:
- `ConsentGate` (`picpal/Sources/App/ConsentGate.swift`): pure value type.
  - `static let consentKey = "com.picpal.consent.version"` — versioned (allows re-prompting after privacy policy updates).
  - `static let currentConsentVersion: Int = 1`.
  - `static func isConsentGiven() -> Bool` — reads UserDefaults.
  - `static func recordConsent(cloudEnabled: Bool)` — writes consent version AND sets `VLMSettings.shared.isOnDeviceOnly = !cloudEnabled`.
- No consent = on-device-only for the session (default `isOnDeviceOnly = true` until consent is given).

**ContentView wiring**
- `@State private var showConsentSheet: Bool` — initialized to `!ConsentGate.isConsentGiven()`.
- `.fullScreenCover(isPresented: $showConsentSheet) { ConsentSheet { choice in ... } }` — shown before camera previews (camera still starts but VLM is blocked by `isOnDeviceOnly`).
- `ConsentSheet` calls `ConsentGate.recordConsent(cloudEnabled:)` and sets `showConsentSheet = false`.
- After consent, re-create `VLMOrchestrator` with the new `isOnDeviceOnly` setting — or simply `vlmOrchestrator?.update(isOnDeviceOnly: VLMSettings.shared.isOnDeviceOnly)`. Choose whichever is cleaner; if VLMOrchestrator doesn't support live update, re-wire only the VLM path (not the whole pipeline).

**`ConsentSheet`** — `picpal/Sources/UI/ConsentSheet.swift`
- Full-screen modal, not a sheet (use `.fullScreenCover`, not `.sheet`).
- Shows app icon / name, one-paragraph explanation (use `VLMPrivacyDisclosure.text` for the body).
- Two CTA buttons (primary: "Enable cloud coaching", secondary: "Stay on-device only").
- A "What data is shared?" disclosure link that expands inline.
- No dismiss gesture (must tap a button — consent cannot be skipped).

**Acceptance criteria**

- [ ] `ConsentGate.isConsentGiven()` returns false before any consent is recorded.
- [ ] `ConsentGate.recordConsent(cloudEnabled: true)` sets consent version key and `VLMSettings.shared.isOnDeviceOnly = false`.
- [ ] `ConsentGate.recordConsent(cloudEnabled: false)` sets consent version key and `VLMSettings.shared.isOnDeviceOnly = true`.
- [ ] On first launch (consent not given): `ConsentSheet` appears before any camera frame could reach VLMOrchestrator. VLMOrchestrator is initialized with `isOnDeviceOnly = true` until consent is given.
- [ ] On subsequent launches (consent given): no `ConsentSheet` is shown; `isOnDeviceOnly` reflects the user's recorded preference.
- [ ] `ConsentSheet` cannot be dismissed without tapping a button (no swipe-down, no tap-outside).
- [ ] Privacy copy uses `VLMPrivacyDisclosure.text` — no new ad-hoc strings.
- [ ] Unit tests: `ConsentGate` read/write round-trip (use a separate UserDefaults suite, not `.standard`, so tests don't pollute device state).

---

## M4-4 — Post-session survey
**Size**: S · **Deps**: M4-2 (session lifecycle) and M4-3 (consent gate wiring)

**Goal**: Measure the primary KPI — "did the coaching feel real-time?" — from actual users. A single-question 5-point Likert scale shown at the end of each session. Response is stored locally and included in the `TelemetryExporter` snapshot.

**`PostSessionSurvey`** — `picpal/Sources/App/PostSessionSurvey.swift`
```swift
struct PostSessionSurvey: Sendable {
    static let surveyKey = "com.picpal.survey.lastResponse"
    static let sessionCueThreshold = 3   // minimum cues before showing survey

    /// 1 = Never, 2 = Rarely, 3 = Sometimes, 4 = Often, 5 = Always
    static func record(response: Int) {
        UserDefaults.standard.set(response, forKey: surveyKey)
    }
    static func lastResponse() -> Int? {
        let v = UserDefaults.standard.integer(forKey: surveyKey)
        return v > 0 ? v : nil
    }
}
```

**ContentView wiring**
- `@State private var showSurvey: Bool = false`.
- On app going to background: if `cueLogger.events().count >= PostSessionSurvey.sessionCueThreshold`, set `showSurvey = true`.
- `.sheet(isPresented: $showSurvey) { PostSessionSurveySheet { response in ... } }`.
- In the survey callback: call `PostSessionSurvey.record(response:)`, build + export snapshot with `surveyResponse: response`.
- Survey is shown at most once per app lifecycle (reset `showSurvey = false` after the sheet is dismissed).

**`PostSessionSurveySheet`** — `picpal/Sources/UI/PostSessionSurveySheet.swift`
- Title: "Quick check".
- Question: "Did the coaching cues come fast enough to act on?"
- 5 large tap-target buttons labeled: "Never" / "Rarely" / "Sometimes" / "Often" / "Always".
- "Skip" text button at the bottom (does NOT record a response; dismisses without export).
- Minimal design — 1 screen, no navigation.

**Acceptance criteria**

- [ ] Survey appears only after ≥ `sessionCueThreshold` cues have been emitted in the session.
- [ ] Survey appears at most once per app lifecycle (not after every background transition).
- [ ] Tapping a scale button records the response AND triggers telemetry export (response included).
- [ ] Tapping "Skip" dismisses without recording and without triggering export.
- [ ] `PostSessionSurvey.lastResponse()` returns `nil` before any response is recorded, and the integer 1–5 after.
- [ ] Unit tests: `record` / `lastResponse` round-trip; threshold guard (< threshold → survey not shown).

---

## M4-5 — Runtime tuning panel + cadence config
**Size**: M · **Deps**: none (new `TuningSettings` singleton, minor CueEngine + VLMRequestGate changes)

**Goal**: Enable A/B tuning of the key coaching parameters without rebuilds. All changes persist across launches in DEBUG builds; production builds always use the hard-coded defaults.

**`TuningSettings`** — `picpal/Sources/App/TuningSettings.swift`

```swift
#if DEBUG
/// UserDefaults-backed runtime tuning knobs. DEBUG builds only.
final class TuningSettings {
    static let shared = TuningSettings()
    private init() {}

    private enum Keys {
        static let cueCooldown       = "com.picpal.tuning.cueCooldown"
        static let minRepeatInterval = "com.picpal.tuning.minRepeatInterval"
        static let vlmCadence        = "com.picpal.tuning.vlmCadence"
        static let aestheticExpiry   = "com.picpal.tuning.aestheticExpiry"
    }

    var cueCooldownSeconds: Double {
        get { stored(Keys.cueCooldown, default: CueEngine.defaultCueCooldownSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cueCooldown) }
    }
    var minRepeatIntervalSeconds: Double {
        get { stored(Keys.minRepeatInterval, default: CueEngine.defaultMinRepeatIntervalSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.minRepeatInterval) }
    }
    var vlmCadenceSeconds: Double {
        get { stored(Keys.vlmCadence, default: VLMRequestGate.defaultCadenceSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.vlmCadence) }
    }
    var aestheticExpirySeconds: Double {
        get { stored(Keys.aestheticExpiry, default: CueEngine.defaultMinRepeatIntervalSeconds + 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.aestheticExpiry) }
    }

    func resetToDefaults() {
        [Keys.cueCooldown, Keys.minRepeatInterval, Keys.vlmCadence, Keys.aestheticExpiry]
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private func stored(_ key: String, default fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
#endif
```

**`VLMRequestGate` change**: Add `static let defaultCadenceSeconds: Double = 8.0` named constant (replace any bare `8.0` literal). In production: reads `VLMRequestGate.defaultCadenceSeconds`. In debug: `ContentView.wireUp()` creates `VLMRequestGate(cadenceSeconds: TuningSettings.shared.vlmCadenceSeconds)`. VLMRequestGate already takes parameters at init — this is a constructor injection, not a static change.

**`TuningPanel`** — `picpal/Sources/UI/TuningPanel.swift`

```swift
#if DEBUG
struct TuningPanel: View {
    @State private var settings = TuningSettings.shared
    var body: some View {
        Form {
            Section("Cue engine") {
                LabeledContent("Cooldown") { Stepper(...) }
                LabeledContent("Repeat interval") { Stepper(...) }
            }
            Section("VLM") {
                LabeledContent("Cadence") { Stepper(...) }
                LabeledContent("Remark expiry") { Stepper(...) }
            }
            Section {
                Button("Reset to defaults") { settings.resetToDefaults() }
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Tuning")
    }
}
#endif
```

**DebugOverlayView change**: Add a long-press gesture on the debug overlay that presents `TuningPanel` as a sheet (DEBUG only). Gate with `#if DEBUG`.

**ContentView change**: In `wireUp()`, read tuning settings before creating `CueEngine` and `VLMRequestGate`:

```swift
#if DEBUG
let engine = CueEngine(
    cueCooldownSeconds: TuningSettings.shared.cueCooldownSeconds,
    minRepeatIntervalSeconds: TuningSettings.shared.minRepeatIntervalSeconds
)
let gate = VLMRequestGate(cadenceSeconds: TuningSettings.shared.vlmCadenceSeconds)
#else
let engine = CueEngine()
let gate = VLMRequestGate()
#endif
```

**Acceptance criteria**

- [ ] `TuningSettings` exists only in `#if DEBUG` compilation guard — zero symbols in release binary.
- [ ] `VLMRequestGate.defaultCadenceSeconds = 8.0` named constant; no bare `8.0` literals.
- [ ] In debug: `CueEngine` is constructed with `TuningSettings.shared` values; changing them in TuningPanel and relaunching uses the new values.
- [ ] `TuningPanel` is reachable via long-press on DebugOverlayView in debug builds; absent in release builds.
- [ ] `resetToDefaults()` clears all tuning keys; next `wireUp()` uses the hardcoded defaults.
- [ ] Unit test: `TuningSettings.resetToDefaults()` then reading each property returns the named default.

---

## M4-6 — Validation session kit
**Size**: S · **Deps**: none

**Goal**: Provide a structured task set for moderated usability sessions without requiring a moderator to read from a separate document. A debug-only overlay cycles through tasks so the participant knows what to do.

**`SessionTask`** — `picpal/Sources/App/SessionTask.swift`

```swift
struct SessionTask: Sendable, Identifiable {
    let id: Int
    let title: String
    let instructions: String
}
```

**`SessionTaskScript`** — same file

```swift
enum SessionTaskScript {
    static let m4Tasks: [SessionTask] = [
        SessionTask(id: 1,
            title: "Photograph a person",
            instructions: "Ask your participant to stand 1–2 m away. Frame them while the app coaches you."),
        SessionTask(id: 2,
            title: "Obstruct the lens",
            instructions: "Rest a finger on the lower edge of the lens. Verify the obstruction cue fires within 2s."),
        SessionTask(id: 3,
            title: "Check tilt recovery",
            instructions: "Tilt the phone 15° left. Wait for the tilt cue. Return to level. Cue should silence."),
        SessionTask(id: 4,
            title: "Check blur recovery",
            instructions: "Shake the phone briefly. Wait for the blur cue. Stabilise. Cue should silence."),
        SessionTask(id: 5,
            title: "VLM aesthetic cue",
            instructions: "Hold a stable, novel frame for 10s. Verify a spoken composition remark arrives."),
        SessionTask(id: 6,
            title: "VLM offline degradation",
            instructions: "Disable Wi-Fi. Hold a stable frame for 30s. Verify no error cue fires."),
        SessionTask(id: 7,
            title: "5-min battery session",
            instructions: "Run the full pipeline for 5 minutes with a person in frame. Note thermal and battery."),
        SessionTask(id: 8,
            title: "Non-annoyance check",
            instructions: "Frame a good shot. Observe 60s. Count cues. Target: ~1–3 total (not per subject)."),
    ]
}
```

**`SessionTaskOverlay`** — `picpal/Sources/UI/SessionTaskOverlay.swift`

```swift
#if DEBUG
struct SessionTaskOverlay: View {
    let tasks: [SessionTask]
    @State private var currentIndex: Int = 0
    // displays current task title + instructions
    // Previous / Next buttons
    // "Done" button hides the overlay
}
#endif
```

**ContentView change**: Add `@State private var showSessionKit: Bool = false`. In `DebugOverlayView`, add a "Session" button (DEBUG only) that sets this flag. Present `SessionTaskOverlay` as a sheet when true.

**Acceptance criteria**

- [ ] `SessionTaskScript.m4Tasks` has exactly 8 tasks covering: person framing, obstruction, tilt, blur, VLM cue, VLM offline, battery session, non-annoyance check.
- [ ] `SessionTaskOverlay` cycles through tasks with previous/next controls; current task number is shown (e.g., "3 / 8").
- [ ] Overlay is reachable from DebugOverlayView; absent from release builds.
- [ ] No production code paths reference `SessionTask` or `SessionTaskScript`.
- [ ] Unit test: `SessionTaskScript.m4Tasks` has 8 tasks, each with unique ID, non-empty title and instructions.

---

## M4-7 — Integration, deployment & validation  ⚠ PENDING_DEVICE_RUN
**Size**: L · **Deps**: M4-0 through M4-6

**Goal**: Run moderated sessions using the `SessionTaskScript.m4Tasks` task set, collect `TelemetryExporter` snapshots and post-session survey responses, compute KPIs, and iterate on tuning constants until KPIs are met.

**KPI targets**
| KPI | Target | How measured |
|-----|--------|--------------|
| "Feels real-time" | ≥70% respond Often/Always (4–5) | Post-session survey |
| Actionable latency | p50 settle→first cue < 150ms | `CueTelemetryReport.medianSettleLatencyMs` |
| Non-annoyance | ~1–3 cues per stable episode | Manual count from session video + log |
| FPS non-regression | p95 frame time ≤ 33ms with VLM active | `TelemetrySnapshot.frameStats.p95Ms` |
| Battery (5-min) | ≤3% drain | `BatteryReport.drainPercentage` |

**Codeable subset (implement now)**
- Update `docs/demo-script.md`: add `## M4 — Tuning & Validation` section with 8 sub-sections mirroring `SessionTaskScript.m4Tasks`, each marked `PENDING_DEVICE_RUN`.
- Update `.superpowers/sdd/progress.md` with M4 branch and base commit.

**Device-dependent (PENDING_DEVICE_RUN)**
- Run all 8 session tasks on ≥3 real devices (iPhone 14 or later).
- Export telemetry from each session; collate survey responses.
- Compute KPIs from exported JSON using the `jq` commands documented in `demo-script.md`.
- Adjust `TuningSettings` if KPIs not met; re-run sessions until targets are hit or iteration budget is exhausted.
- Document final tuning constants in a `## Validated configuration` section in `demo-script.md`.
- Final whole-branch review before merging to `develop`.

---

## Global constraints

These apply to every task in M4 — reviewers check them:

- **No bare numeric literals** — all magic numbers are `static let` named constants.
- **File limit** — no new file exceeds 300 lines. Split if needed.
- **Swift Testing only** — `import Testing`, `@Test`, `#expect`. No `XCTestCase`.
- **Debug-only symbols** — `TuningSettings`, `TuningPanel`, `SessionTaskOverlay`, `SessionTaskScript` are gated with `#if DEBUG`. They must not appear in release binaries.
- **No UserDefaults in `TuningSettings` init** — reads are lazy (called at first access, not at class init time) to avoid startup-order bugs.
- **Consent gate precedes VLMOrchestrator** — no frame is encoded and sent to the proxy before `ConsentGate.isConsentGiven()` returns `true` or the user actively chooses cloud-on. Verify: on first launch, `isOnDeviceOnly` is `true` until consent is recorded.
- **API key off-device** — unchanged from M3: key is in proxy environment only. Reviewers verify no key in source, binary, or `project.yml`.
- **Tier-0 forwarding invariant** — unchanged.
