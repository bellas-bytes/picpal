# Pose feedback release evidence

Status: **incomplete; real-photo and physical-device claims are unverified**.

| Evidence | Current result | Required record |
| --- | --- | --- |
| Rights-cleared real benchmark | 0 records | Private manifest version/hash, rights review, connected split |
| Real native baseline / candidate replay | Not run | Revision, OS/device, detector settings, JSONL and scored report |
| Correction precision / coverage | Not measured | Numerators/denominators by slice and participant; participant uncertainty; proposed targets 90% / 70% |
| Opposite directions / false full-match / auto-capture | Not measured on real assets | Zero curated-regression events; report every real-data event |
| Following instruction reduces detail error | Not measured | Human-adjudicated clips; proposed target 80% |
| Unjustified cue reversals | Not measured | Stable 10-second clips; proposed maximum one reversal |
| Visible cue latency | Not measured | Same-phone baseline/candidate p95; proposed <500 ms, <10% regression |
| Thermal / battery | Not measured | Repeated five-minute phone sessions |
| Portrait / landscapes / camera flip / opacity / minimum zoom | Requires app and phone checks | Screenshots, retained preview identity and physical observations |
| Training | Not started; gate deferred | See training-decision.md |

Record software test results separately from measured accuracy. The Node scorer suite validates denominators, abstention, labels and leakage; Swift numeric tests validate geometry and state behavior. Neither establishes accuracy on real selfies. Fill this report with exact artifacts and counts after collection; do not replace missing evidence with test totals.

## Software verification (2026-09-28)

- Evaluation suites: 15 passed (12 pose-feedback, 3 existing reference-coaching).
- Proxy regression suite: 17 passed.
- Final full iOS suite: 848 tests across 102 suites passed, including the explicit-focus crop regression (`/tmp/picpal-person-focus-full.log`).
- Final signed generic iOS Debug build succeeded (`/tmp/picpal-person-focus-device-build.log`).
- Rendered portrait and landscape control fixtures include focus, overlay opacity and expanded zoom; these do not replace physical-device checks.
- Independent review covered focus isolation, raw replay parity, local landmark confidence and capture gating. Default All mode retains framing-first behavior for person-domain references.
