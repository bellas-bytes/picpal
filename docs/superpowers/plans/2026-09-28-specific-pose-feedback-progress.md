# Specific pose feedback execution record

Branch: `codex/specific-pose-feedback`, created from `codex/reference-understanding` at `1a130c5`.
Prerequisite baseline: `9f1342e` preserves the earlier session's uncommitted camera/coaching work and plan in a separate commit.

Decisions:
- Work in the requested new branch in the shared checkout; preserve the accumulated prior work as a baseline rather than dropping dependencies or modifying the parent branch.
- Implement evaluation tooling and collection protocol without fabricating real labels/data. The 100-pair/20-clip consented pilot and human annotation remain an external collection task; no model training or real-world accuracy claim until that evidence exists.
- Keep the current model/detectors. Training remains conditional on measured failure analysis.

Ownership:
- Pose engineer: richer observations, target compilation, comparison, cue integration and tests.
- Evaluation engineer: private-asset replay, manifest validation/scoring, tests and training decision report.
- Root: session focus selection, UI/model integration, project generation, reviews, full verification and commits/push.

Status: implementation complete and reviewed. Real benchmark collection remains outstanding.

Implementation/review results:
- Task 1: manifest/schema/private-path checks, leak-resistant split validation, JSONL scorer and opt-in native raw-asset replay implemented. Twelve scorer tests pass. Real asset collection/annotation and baseline measurement remain outstanding external work; the empty manifest cannot pass release gates.
- Tasks 2–4: rich joint confidence, head/hand/shoulder measurements, target compiler, ranked corrections and coordinator retention implemented. Plan extension preserves a separate 0.5 local landmark-quality floor without changing the 0.65 cloud gate or inflating raw confidence. No semantic cheek claim or palm/depth estimate without supporting measurements.
- Task 5: focus selector and session state implemented. Focus changes clear progress/cloud generation while preserving camera geometry. Rendered portrait/landscape fixtures include focus, opacity and expanded zoom. Physical phone interaction and real correction success are not yet evaluated.
- Task 6: training-decision report records no training until rights-cleared evidence establishes the failing component.
- Independent review found restricted-focus body-cue leakage and replay reference-domain divergence; both fixed and reviewed. Focus and local-quality bugs were reproduced in regression tests before fixing. Replay completion export also retains completed-detail identity when the active cue changes.
- Proxy regression suite: 17 passed after rerunning with local socket permission. Evaluation suites: 15 passed (12 pose + 3 existing reference).
- First full iOS run: 847 tests, one test-only floating-point equality failure; changed rectangle comparison to 1e-6 tolerance, retained exact face-domain assertion, reviewer approved. Subsequent full run passed all 847 tests across 102 suites, and the signed iOS build succeeded.
- Final review identified an additional explicit-focus edge case: person-domain references with mismatched framing suppressed supported detail cues. The regression failed before the scoped fix and passed afterward; independent review approved it. Default All mode retains framing-first behavior for person-domain references; independence is not universal.
- Final full iOS run passed 848 tests across 102 suites (`/tmp/picpal-person-focus-full.log`).
- Final signed generic iOS Debug build succeeded (`/tmp/picpal-person-focus-device-build.log`).
