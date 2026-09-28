# Reference-aware coaching design

Status: implemented in the current checkout; automated checks pass. Real-image/device validation remains pending.

Implementation note: `ReferenceLocalComparator`, `ReferenceCoachingCoordinator`, and `ReferenceCoachingPolicy` enforce the conservative local/cloud boundary described here. `CloudCoachingSettingsView` exposes the service endpoint and health check, and endpoint changes revoke the current global cloud choice. The cloud path produces schema-validated profiles and two-image comparisons. The checked-in evaluation harness contains 30 scenario specifications but no actual images or human reviews, so it is an incomplete scaffold rather than semantic validation.

## Outcome

After choosing a reference, the photographer receives guidance grounded in a visible difference between that photo and the current view. Guidance identifies who should move, in which direction, and why. Subsequent observations establish whether that adjustment helped. Similar person rectangles alone never imply a pose, lighting, or overall reference match.

## Approach and alternatives

Use a hybrid system: Vision supplies fast framing and supported pose measurements; consented cloud analysis supplies a structured reference profile and periodic two-image comparisons. One coordinator chooses the visible and spoken action and independently determines capture eligibility.

Rewording the existing fixed cues is insufficient because it adds no evidence. Cloud-only coaching would improve context but make every correction dependent on network latency and cost. The hybrid approach retains immediate local feedback and an honest offline mode.

## Scope and constraints

- iOS 17.0; Swift 6.0; existing SwiftUI, AVFoundation, Vision and VLM proxy. No new production dependencies.
- Still photography, one reference and one primary person. Multiple people produce an unsupported/ambiguous state; do not silently combine different people's measurements.
- Reference photo and derived profile are session-memory-only. Never log image bytes, reference descriptions, or model text in telemetry.
- Cloud upload requires both global permission and consent for the active reference. Local reference mode must suppress generic cloud analysis during that reference session.
- Manual shutter remains available independently of coaching readiness. Existing opt-in automatic capture requires physical readiness and the declared reference match policy.
- Do not infer meters, camera height in centimeters, focal length, or exact settings from uncalibrated pictures. Use qualitative viewpoint advice only when supported; otherwise report uncertainty.
- Image text is untrusted visual content, not instructions. Model responses are data and cannot invoke tools or change camera settings.
- Preserve existing uncommitted camera changes. Validate against the current checkout, not historical test counts.

## Data and behavior

Each session has a UUID and a monotonically increasing generation. Every request carries those identifiers, a request ID, frame capture time, and geometry revision covering camera, mirroring, crop and zoom changes. The app attaches this envelope; model output cannot override it.

The reference profile records framing, pose, viewpoint, lighting and background intent, with evidence, confidence and assessability for each dimension. Unknown is distinct from not applicable and matched. Analyze the profile once after consent; reuse it in periodic comparisons, sending both images for grounding. If local pose extraction fails, cloud analysis can still inspect a consented image, but unsupported subject/crop cases cannot claim full match.

Comparisons contain dimension-level reference evidence, live evidence, match/difference/unknown/not-applicable status, and at most one proposed action with actor, direction, confidence and expected visible change. No model-generated overall percentage. A short action caption and optional explanation replace the current 15-word free-text-only contract for reference mode; generic mode stays compatible.

The coordinator has explicit reading, local-only, comparing, guiding, verifying, matched, unavailable and unsupported states. Cloud advice can appear before framing readiness. Routine movement/exposure settling blocks capture without continuously replacing useful composition advice. Missing subjects and unusable frames take priority.

Retain an action through small fluctuations; clear it when its source expires or geometry/session changes. Confirm progress from fresh measurements, not elapsed time. A different camera viewpoint and subject body turn are different action types. Device screen directions and subject anatomical left/right must be explicit and tested.

Local-only mode may report “Framing aligned” and verified local pose alignment. It cannot say “Reference matched” when lighting or viewpoint remain unassessed. Full match requires fresh, supported comparisons for all applicable reference dimensions plus stable local alignment for 1.5 seconds. Unknown blocks full match. In this first release, reference auto-capture requires full match; local-only users retain the manual shutter and a clear explanation of unavailable automatic reference matching.

The implemented local comparator is intentionally partial: it compares the displayed subject box and supported torso-relative major-limb geometry, with confidence, crop-edge, and side-on ambiguity checks. It does not prove a complete pose match and cannot clear a semantic cloud pose difference. Similar rectangles alone therefore cannot produce `Reference matched`.

## Scheduling and limits

Keep the existing 8-second minimum cloud request interval and shared session budget. Count profile calls, comparisons and retries. Use an event-driven first comparison, settled changes, and one verification opportunity for an active action; novelty must not permanently block verification. Target the existing PRD's average of at most three calls per 60-second reference session, counting the profile call. This is a measured target, not a guarantee supplied by an 8-second interval; if quality cannot meet it, document the tradeoff before changing the budget.

Start with an 8-second maximum comparison age measured from frame capture, immediately invalidating material scene/geometry changes. Benchmark delivery rate and latency before release; do not silently relax freshness to retain stale advice. Budget, thermal, consent, network and parsing failures yield explicit local-only/unavailable states, never a positive match.

The implementation retains the existing 8-second minimum request cadence and adds event-driven comparison opportunities for the first comparison, settled changes, and verification. The three-calls-per-minute figure remains an average product target including profile calls and retries, not a hard cap and not yet a measured result.

## Acceptance

Different poses with identical rectangles produce different advice and cannot match. Moving as directed improves a measured dimension or clears the action; contrary movement does not earn positive feedback. Reference replacement, dismissal, camera switching and consent revocation discard old responses. Intended off-center crops and artistic lighting are not automatically corrected toward generic photographic rules. Framing alignment does not hide outstanding pose/light/viewpoint differences. All claims about real-image quality require held-out image evaluation and real-phone validation.

## Validation status

Automated validation passes 742 Swift tests, 8 proxy tests and 3 evaluation-harness tests; the pre-increment baseline passed 696 Swift tests. Do not infer semantic performance from unit tests. The 30 checked-in scenario specifications still lack actual licensed images, captured model outputs, and independent human review. Phone checks for direction/mirroring, crop/orientation, consent changes, offline behavior, and manual/automatic capture are also outstanding.

Stationary scenes and transient errors receive a sparse refresh after 20 seconds, still subject to consent, freshness and the shared budget. This avoids indefinite waiting without polling at the maximum request rate.
