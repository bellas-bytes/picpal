# Reference Understanding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give one actionable, evidence-based adjustment toward the selected reference, verify improvement, and stop treating rectangle alignment as an overall match.

**Architecture:** Add typed reference analysis alongside the existing generic VLM path. Combine fresh local observations and structured cloud comparisons in one reference-coaching coordinator, which owns guidance and match state; capture readiness remains a separate input.

**Tech Stack:** Swift 6.0, iOS 17.0, SwiftUI, AVFoundation, Vision, Swift Testing, existing Node/Express VLM proxy.

**Spec:** `docs/superpowers/specs/2026-09-16-reference-understanding-design.md` (proposed alongside this plan).

## Global constraints

- iOS 17.0; Swift 6.0; existing SwiftUI, AVFoundation, Vision and VLM proxy. No new production dependencies.
- Still photography, one reference and one primary person. Multiple people produce an unsupported/ambiguous state; do not silently combine different people's measurements.
- Reference photo and derived profile are session-memory-only. Never log image bytes, reference descriptions, or model text in telemetry.
- Cloud upload requires both global permission and consent for the active reference. Local reference mode must suppress generic cloud analysis during that reference session.
- Manual shutter remains available independently of coaching readiness. Existing opt-in automatic capture requires physical readiness and the declared reference match policy.
- Preserve existing uncommitted camera changes. Validate against the current checkout, not historical test counts.
- No application implementation, dependency upgrades, deployment or API calls are part of this planning change.

## Verified starting points

`ReferenceSession` extracts joints, but `PersonShotCoach.assessReference` compares only subject center, height and headroom. `CameraScreenModel.tick` writes match state from this assessment and displays VLM remarks only when `ready` is true. The legacy `makeReferenceCoachingCallback` is not the active integration path.

`BodySignal` is not a live pose container. The cloud reference response is parsed as an `AestheticSignal` string. `proxy/index.js` uses a 64-token response limit. Reference identity and consent are stored separately; scene-based stale suppression alone cannot reject a response to an old reference. The request gate passes `isSettled: true` and can consume quota before later dispatch checks. Default cloud mode is off and the proxy defaults to localhost, which is not the development Mac when running on a phone.

## Sub-agent ownership and ordering

Use at most three workers plus the coordinating agent. Every worker must be told that they share the workspace, must preserve other edits, and may edit only their assigned files. The coordinator owns cross-component integration and project generation. Workers supply implementation, tests and a concise handoff; the coordinator reviews before proceeding.

| Work package | Owner | Dependencies | Boundary |
|---|---|---|---|
| 1. Contracts and fixtures | Coordinator | Baseline | Freeze types before parallel implementation |
| 2. Structured cloud analysis | Agent A | 1 | Reference prompts/parser, proxy contract, orchestrator lifecycle |
| 3. Local pose/framing comparison | Agent B | 1 | Reference geometry, local observations and delta evaluator |
| 4. Coaching coordinator | Agent C | 1 | Pure state transitions, action arbitration and match policy |
| 5. Camera/UI integration | Coordinator | 2–4 | App wiring, consent, settings, overlay, capture |
| 6. Behavioral evaluation | Agent A after 2 | 1; final run after 5 | Evaluation manifest/harness, no production files |
| 7. Regression and review | Coordinator + reviewer | 5–6 | Serial build, independent review, phone checklist |

Agents A–C may run in parallel only after package 1 fixes shared interfaces. Do not run simultaneous Xcode builds against the same DerivedData. Each package ends with focused passing tests, review and a scoped commit when execution is authorized; never include unrelated dirty files.

## 1. Freeze contracts and add regression fixtures

**Files:** Create `picpal/Sources/Reference/ReferenceAnalysis.swift`, `picpal/Tests/PicPalTests/ReferenceAnalysisTests.swift`, and `picpal/Tests/PicPalTests/Fixtures/ReferenceAnalysis/`. Coordinator owns these files.

Define `Codable`, `Sendable` value types (and `Equatable` for reducer tests):

```swift
enum ReferenceDimension: String, Codable, Sendable {
    case framing, pose, viewpoint, lighting, background
}
enum DimensionStatus: String, Codable, Sendable {
    case matched, different, unknown, notApplicable
}
enum ActionActor: String, Codable, Sendable { case photographer, subject }
struct ReferenceEnvelope: Sendable, Equatable {
    let sessionID: UUID
    let generation: UInt64
    let requestID: UUID
    let capturedAt: TimeInterval
    let geometryRevision: UInt64
}
```

Additional exact contract fields: `ReferenceFeature(dimension: ReferenceDimension, evidence: String, confidence: Double, applicable: Bool)`; `ReferenceProfile(schemaVersion: Int, summary: String, features: [ReferenceFeature])`; `ReferenceAction(id: String, dimension: ReferenceDimension, actor: ActionActor, direction: String, instruction: String, expectedChange: String, confidence: Double)`; `ReferenceDimensionComparison(dimension: ReferenceDimension, status: DimensionStatus, referenceEvidence: String, liveEvidence: String, confidence: Double)`; `ReferenceComparison(schemaVersion: Int, dimensions: [ReferenceDimensionComparison], action: ReferenceAction?)`. Action IDs are normalized by the app, not trusted for continuity solely because the model repeats them.

- [ ] Write decoding tests for a complete comparison, missing dimension, duplicate dimension, invalid enum, nonfinite/out-of-range confidence and oversized text. Require each of the five dimensions exactly once; unknown must have no asserted correction for that dimension.
- [ ] Run the new suite and confirm failure before implementing validation.
- [ ] Implement strict schema-v1 validation: confidence in 0...1; summary/evidence/expected-change at most 240 characters, direction at most 80, instruction at most 120. Reject malformed responses rather than extracting an arbitrary sentence.
- [ ] Store fixtures for same rectangle/different pose, framing matched/light different, unknown viewpoint, true supported match, and no detected subject. Keep JSON fixtures free of personal images.
- [ ] Run tests, review contracts with all workers, then commit only this package.

Representative assertion (using a checked-in JSON fixture):

```swift
let comparison = try ReferenceAnalysisParser.parseComparison(fixtureData)
#expect(comparison.dimensions.first { $0.dimension == .pose }?.status == .different)
#expect(comparison.action?.actor == .subject)
```

`ReferenceAnalysisParser.parseProfile(_ data: Data) throws -> ReferenceProfile` and `parseComparison(_ data: Data) throws -> ReferenceComparison` are implemented in package 2; package 1 freezes their signatures and fixture expectations.

## 2. Structured analysis and generation-safe requests — Agent A

**Create:** `picpal/Sources/VLM/ReferenceAnalysisParser.swift`, `picpal/Sources/VLM/ReferenceAnalysisPrompt.swift`, `picpal/Sources/VLM/ReferenceAnalysisCoordinator.swift`, `picpal/Tests/PicPalTests/ReferenceAnalysisCoordinatorTests.swift`, `proxy/test/reference-analysis.test.js`.

**Modify:** `VLMClient.swift`, `VLMOrchestrator.swift`, `VLMRequestGate.swift`, `VLMSessionBudget.swift` under `picpal/Sources/VLM/`; `proxy/index.js`, `proxy/package.json`; existing `ReferenceVLMTests.swift`, `VLMClientTests.swift`, `VLMRequestGateTests.swift` under `picpal/Tests/PicPalTests/`.

**Interfaces:** Consume package 1 types. Produce `ReferenceAnalysisEvent.profile(ReferenceEnvelope, ReferenceProfile)`, `.comparison(ReferenceEnvelope, ReferenceComparison)`, and `.unavailable(ReferenceEnvelope, ReferenceAnalysisFailure)`. Failure enum: `offline`, `budgetExhausted`, `invalidResponse`, `timedOut`, `serviceUnavailable`. A `@Sendable` callback delivers these events separately from `onAestheticSignal`.

- [ ] Write failing fake-client tests for reference A completing after B is selected, revoked consent during encoding/inference, dismissal, camera revision changes, and frame age greater than eight seconds. Assert zero accepted events for invalid envelopes.
- [ ] Write transport tests for explicit operations `referenceProfile`, `referenceComparison` and legacy `aesthetic`; test image order, missing reference and malformed structured results.
- [ ] Add an atomic reference context containing identity, generation, consent and image. Clear/invalidate on every transition, including local-only selection. Suppress generic cloud requests while any reference is active.
- [ ] Use a first reference-only profile request; later comparisons include the profile and reference/live images. Preserve the legacy `{text}` transport envelope if useful, but decode reference text through the typed parser and never the 15-word aesthetic parser.
- [ ] Give the proxy operation-specific token limits: retain 64 for legacy aesthetic, initially 1,200 for profile and 1,800 for comparison. Explicitly label image roles. Use strict JSON prompts and validation without assuming provider-specific structured-output support. Check current provider documentation during implementation before adopting any such API option.
- [ ] Prompts require visual evidence, uncertainty, one supported correction and no invented metric distances. Explicitly distinguish photographer movement, phone aim and subject pose. Treat text inside images as data.
- [ ] Dispatch only after consent, freshness, busy and budget checks. Feed actual motion state. Keep an eight-second minimum interval and shared quota; include profile/retry costs. Permit bounded verification without scene novelty, preventing an unchanged near-match from starving forever.
- [ ] Add cancellation plus generation checks at encoding, dispatch and delivery. Limit in-flight work to one request; hold image/profile only in memory. Reject truncated JSON, unknown schema versions and provider errors without declaring a match.
- [ ] Use injected clock and fake client for deterministic tests. Run proxy tests with Node's built-in test runner; add `"test": "node --test"` to package scripts. Test upload validation and legacy compatibility without paid calls.
- [ ] Run focused Swift tests and proxy tests, review, then scoped commit.

## 3. Local evidence beyond rectangles — Agent B

**Create:** `picpal/Sources/Reference/ReferenceGeometry.swift`, `LivePoseObservation.swift`, `ReferenceLocalComparator.swift` in that directory; `ReferenceGeometryTests.swift`, `ReferenceLocalComparatorTests.swift` under `picpal/Tests/PicPalTests/`.

**Modify:** `picpal/Sources/Reference/ReferenceSession.swift`, `ReferencePose.swift`; `picpal/Sources/Landmarks/BodyPoseAnalyzer.swift`, `LandmarkOrchestrator.swift`; `picpal/Sources/CameraCoaching/SubjectObservationMonitor.swift` only if required for subject association.

**Interfaces:** `LivePoseObservation` includes captured time, geometry revision, person box, joints with per-joint confidence, optional face yaw, and subject count. `ReferenceLocalComparator.compare(reference: ReferencePose, live: LivePoseObservation) -> LocalReferenceEvidence`. `LocalReferenceEvidence` carries captured time/revision, `framingAligned: Bool`, `poseAligned: Bool?`, supported dimension comparisons and optional action. Nil pose alignment means unknown.

- [ ] Write failing synthetic-joint tests: identical box with opposite arm placement, raised versus lowered arm, cropped/missing wrist, seated versus standing, and multiple subjects. Assert missing joints never become a match.
- [ ] Add geometry tests for portrait/landscape references, front/rear mirroring and aspect-fit overlay versus aspect-fill preview. Compare in a declared common image space; never compare coordinates from differently cropped images directly.
- [ ] Carry live joints through a dedicated observation callback; do not squeeze them into the coarse `BodySignal` hint or revive the unused legacy reference callback.
- [ ] Normalize pose around torso position and size. Compare supported limb angles/relative positions separately from framing. Start with arm elevation and torso lean; retain unknown for unsupported articulation, occlusion or perspective ambiguity. Use named, fixture-tested tolerances with hysteresis, not whole-frame raw-joint distance.
- [ ] Associate face, joints and rectangle with the same person; if association is ambiguous, suppress pose advice. Keep reference pose data's existing callers compatible while adding confidence metadata.
- [ ] Generate camera-relative framing corrections and subject-relative pose corrections from a documented direction convention. Test both signs and mirrored cases. A joint cannot infer camera height or exact depth.
- [ ] Run local suites and measure comparator execution against the existing <2ms per-frame target on device later; do not claim device performance from simulator timing. Review and scoped commit.

## 4. One coaching and match coordinator — Agent C

**Create:** `picpal/Sources/Reference/ReferenceCoachingCoordinator.swift`, `ReferenceCoachingState.swift`, `ReferenceCoachingPolicy.swift`; `picpal/Tests/PicPalTests/ReferenceCoachingCoordinatorTests.swift`.

**Interfaces:** Consume packages 1 and 3 types. Define `ReferenceCoachingInput` with current session/generation/revision, `now`, local evidence, latest profile/comparison envelopes, cloud availability and `captureSafe: Bool`. Produce `ReferenceCoachingDecision(phase: ReferenceCoachingPhase, caption: String, explanation: String?, action: ReferenceAction?, framingAligned: Bool, referenceMatched: Bool, allowsAutoCapture: Bool)`. Phase cases: `reading`, `localOnly`, `comparing`, `guiding`, `verifying`, `matched`, `unavailable`, `unsupported`. `ReferenceCoachingCoordinator.update(_ input: ReferenceCoachingInput) -> ReferenceCoachingDecision` is synchronous with injected time via input; `reset()` clears history.

- [ ] Write failing reducer tests showing an actionable cloud comparison while `captureSafe` is false; identical rectangles with wrong pose; local-only aligned framing; missing/stale comparison; and explicit full match.
- [ ] Reject evidence with mismatched identity/revision or age. Keep missing subject and unavailable observations distinct from alignment.
- [ ] Select one highest-impact supported action; confidence is supporting evidence, not calibrated truth. Prefer direct measurements over conflicting inferred framing. Do not generate alternative generic advice that contradicts the reference.
- [ ] Preserve the chosen action through jitter; require new evidence to reverse it. Reset on geometry/session changes. Track progress only on the active dimension using two fresh observations; expiry enters verifying rather than praise.
- [ ] Separate instruction selection from capture safety. Routine settling blocks capture but keeps a useful action visible; absence or unusable frame replaces it. Rate-limit repeated voice through the existing voice layer.
- [ ] Full match requires all applicable dimensions to be explicitly supported and matched, no outstanding action, fresh comparison, and 1.5 seconds of continuous fresh local alignment. Reset the hold on gaps or contradictions. Never interpret unknown as not applicable.
- [ ] In local-only mode return “Framing aligned” when appropriate, never overall match; automatic reference capture remains unavailable. Manual capture does not depend on this decision.
- [ ] Run reducer tests with fake time; review and scoped commit.

## 5. Wire the camera experience — Coordinator

**Modify:** `picpal/Sources/App/CameraScreenModel.swift`, `ContentView.swift`, `ContentView+Session.swift`, `ContentView+Reference.swift`; `picpal/Sources/CameraCoaching/PersonShotCoach.swift`; `picpal/Sources/UI/ReferenceOverlayView.swift`; `picpal/Sources/VLM/VLMSettings.swift`; existing camera/model, reference integration and auto-capture tests. Update `project.yml` and regenerate `PicPal.xcodeproj` only from this owner.

- [ ] Add failing production-path tests proving the camera displays reference advice before readiness, the overlay cannot turn green from rectangles alone, and a late generic aesthetic remark cannot overwrite reference guidance.
- [ ] Route reference observations and typed VLM events to the coordinator. Keep generic `PersonShotCoach.assess` unchanged for non-reference use. Replace rectangle-only reference readiness and remove or redirect the unused reference callback so there is one match authority.
- [ ] Derive overlay, caption and optional short explanation from the same decision. Reading, local-only and service-unavailable states must be understandable without diagnostics. Avoid an unsupported percentage score.
- [ ] Connect auto-capture to `allowsAutoCapture` plus hardware safety. Verify manual shutter, retry-save, flash/timer and existing zoom behavior remain independent. Keep reference automatic zoom off to avoid counteracting physical movement.
- [ ] Increment geometry revision on camera switches, zoom changes and preview/capture coordinate changes; reset hold and stale evidence. Reference replacement, backgrounding and consent changes clear queued speech and analysis.
- [ ] Make cloud service reachability/setup visible in the existing settings experience, including an editable development endpoint and health status. Do not enable uploads or change consent automatically. Explain the local framing fallback when service configuration is absent; do not imply localhost reaches the Mac from a phone.
- [ ] Convert copied-logic integration tests to exercise the production coordinator and camera path. Revise `ReferenceCoachTests.swift` cases that currently allow an `isNewMatch` flag to override a large mismatch; legacy flags must never bypass the new evidence-backed match policy. Run focused integration tests and inspect UI states with deterministic injected fixtures.
- [ ] Review integration and generated project diff, then scoped commit.

## 6. Evaluate whether advice is actually useful — Agent A

**Create:** `evals/reference-coaching/README.md`, `manifest.json`, `evaluate.mjs`, `results/.gitkeep`. Evaluation images must be licensed/test-owned and explicitly approved for cloud evaluation; never export users' selected reference photos.

- [ ] Build 30 labeled reference/live scenarios: six framing, six pose (including identical rectangles), four viewpoint, four lighting, four matching, and six ambiguous/unsupported cases. Include cropped portraits, intentional asymmetry, mirrored front-camera views and a scene requiring relocation rather than an impossible instant lighting correction.
- [ ] Annotate acceptable action actors/directions, visible evidence, applicable dimensions and forbidden claims. Do not demand exact sentence matches. Include improved and worsened follow-up frames for at least ten scenarios. Reuse the same live frame with different reference images in at least three controls: the expected advice must change with the reference.
- [ ] Implement a manifest validator and saved-response scoring first; default evaluation must work offline. Live mode must be explicit, use the configured proxy and test-image consent, cap requests and report call count/latency/failures.
- [ ] Hold out ten scenarios from prompt tuning. Human-review all held-out responses; do not use the generating model as the sole judge of its own advice.
- [ ] Release gates: zero false overall matches on known mismatches/unknown cases; zero wrong-direction actions in deterministic geometry fixtures; at least 90% of assessable held-out cases grounded and actionable by human rubric; at least 80% of labeled follow-up sequences correctly recognize improvement/worsening. Report raw counts because the set is small.
- [ ] Record stale-discard rate, time to first useful action, accepted-response latency and calls per minute. Investigate if fewer than 90% of successful controlled-network responses arrive within the eight-second freshness window. Check the three-calls/minute average target; document any unmet gate rather than relabeling it as passed.
- [ ] Review evaluation design/results, then scoped commit.

## 7. Verification and handoff

- [ ] Record current `git status` and a baseline build before implementation. Do not overwrite existing work or commit a mixed baseline. Use the existing checkout or preserve its complete working state if isolating the work.
- [ ] Discover an available simulator: `xcrun simctl list devices available`. The environment may need approved access to CoreSimulator, SwiftPM and Xcode caches; an access failure is not a test failure or pass.
- [ ] After new source files are included, run `xcodegen generate`. Choose a discovered simulator UUID and run builds serially:

```sh
xcodebuild test -project PicPal.xcodeproj -scheme PicPal \
  -destination 'platform=iOS Simulator,id=<discovered simulator UUID>' \
  -derivedDataPath /tmp/picpal-reference-derived \
  -resultBundlePath /tmp/picpal-reference-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Use a fresh result-bundle path if it already exists. For focused runs add `-only-testing:PicPalTests/ReferenceCoachingCoordinatorTests` (substitute the package's actual test suite). Run `npm test --prefix proxy` for mocked proxy tests. These are execution instructions, not tests performed during planning.

- [ ] Run the full Swift suite once integration passes, including generic VLM/cache/retry, orientation, voice, camera controls, capture and consent suites. Run saved-response evaluation, then authorized live test-image evaluation.
- [ ] Dispatch an independent code-reviewer agent for correctness and a security reviewer for upload/consent/parser changes. Resolve findings and rerun affected tests. Reviewers do not edit implementation files concurrently with workers.
- [ ] Validate on a real phone: actionable advice before alignment; pose mismatch with matching box; actual improvement after movement; front-camera directions; crop/orientation; stale results after swapping reference; offline/denied cloud; absent person; manual capture; opt-in auto-capture only after supported match; no queued obsolete speech.
- [ ] Update `docs/device-readiness.md`, `docs/picpal-reference-photo-prd.md`, and `picpal/README.md` with actual results, explicit local-only limits, configuration and remaining device risks. Reconcile historical rectangle-match wording and old auto-capture scope with this design.

## Completion definition

The feature is complete only when the integrated production path gives image-grounded actions, verifies progress, rejects stale or uncertain matches, preserves manual photography, and passes automated, held-out visual and phone checks. A stronger prompt or passing mocked tests alone does not establish reference understanding.
