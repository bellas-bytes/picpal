# Reference coaching evaluation

This is an **evaluation scaffold, not a completed visual benchmark**. Thirty labeled scenario specifications are checked in: six framing, six pose, four viewpoint, four lighting, four matching, six ambiguous. Ten are held out from prompt tuning. Ten scenarios have improved and worsened follow-up labels. Three controls require the identical live photo paired with different references.

No personal photos, licensed assets, model outputs, human scores or performance results are included. Image paths and licenses are deliberately null; cloud consent is false. Acquire owned/licensed test images, document permission, and obtain explicit approval before enabling any upload. Do not export users' selected references to this directory. Confirm direction labels against each actual image before freezing the dataset; scenario descriptions alone cannot establish ground truth.

## Offline use

From the repository root:

```
node evals/reference-coaching/evaluate.mjs
node --test evals/reference-coaching/evaluate.test.mjs
node evals/reference-coaching/evaluate.mjs --responses /path/to/saved.json
node evals/reference-coaching/evaluate.mjs --responses /path/to/saved.json --require-gates
```

Default execution validates the manifest and prints raw counts with all unmeasured gates **incomplete**. `--require-gates` exits nonzero while assets or gates remain missing/failed. Saved output is validated with the production proxy contract. No network request occurs without `--live`.

Saved response format:

```json
{
  "schemaVersion": 1,
  "responses": [
    {
      "scenarioID": "same-box-left-arm-low",
      "comparison": {"schemaVersion": 1, "dimensions": [], "action": null},
      "latencyMs": 0,
      "accepted": false,
      "ageAtDeliverySeconds": 0,
      "contextMatched": true,
      "human": {
        "reviewer": "reviewer-name",
        "assessable": true,
        "grounded": false,
        "actionable": false,
        "notes": "Cite visible evidence and explain any forbidden claims."
      },
      "followUps": [
        {"kind": "improved", "human": {"reviewer": "reviewer-name", "recognizedChange": "improved"}},
        {"kind": "worsened", "human": {"reviewer": "reviewer-name", "recognizedChange": "worsened"}}
      ]
    }
  ],
  "controlReviews": [
    {"id": "arm-control", "reviewer": "reviewer-name", "sameLiveVerified": true, "adviceChangesWithReference": false}
  ]
}
```

The abbreviated `dimensions` above is documentation only and intentionally does not pass production validation: actual responses require all five dimensions. Do not use placeholder latency or rubric scores as measured results. Failure records contain `scenarioID` and `error`. `accepted`/age/context fields come from instrumented app observations, not this standalone proxy runner. Follow-up judgment should be based on the app's actual progression behavior and both observed frames, rather than inferring improvement merely from model confidence.

Human rubric: supported visible evidence, correct action actor/direction, feasible instruction that moves toward the particular reference, no unsupported measurements or match claims. Review all ten held-out responses independently; do not let the generating model be its sole judge. Explicitly mark unassessable cases and explain why. Keep held-out images/outputs out of prompt tuning. Direction aliases are labeled per scenario; expand the reviewed label list for equivalent semantics rather than requiring exact instruction sentences.

## Explicit live mode

Populate image paths relative to an approved asset root, license records, and per-scenario `testImageUploadConsent: true` first. The runner validates every selected image/consent before the first request. JPEGs must be at most 5 MB and within the approved asset root.

```
node evals/reference-coaching/evaluate.mjs --live \
  --allow-test-image-upload --asset-root /path/to/approved-test-images \
  --proxy http://localhost:4000/analyze --ids subject-too-small \
  --max-calls 2 --output /path/to/saved.json
```

Live mode requires explicit scenario IDs and endpoint, counts profile plus comparison calls, and rejects selection exceeding the cap (default 4, maximum 60). It performs no retries. It uses production prompts and strict response validation. The initial runner evaluates base pairs only; follow-ups and swapped-reference controls still need separately captured outputs and human review. HTTP errors/latency are recorded. Never run live mode on the checked-in empty manifest and claim an evaluation result.

## Release gates and outstanding measurements

- Zero false full matches on mismatching/unknown cases; zero labeled wrong-direction actions.
- All ten held-out cases reviewed; at least 90% of assessable cases grounded and actionable.
- At least twenty reviewed follow-up frames across ten sequences; at least 80% correctly recognize improvement/worsening.
- All three controls verified with the same live frame and meaningfully different advice.
- Instrument an app session for stale-discard rate, first useful action, accepted-response latency and calls/minute. At least 90% of successful controlled-network responses should fit the eight-second window; target at most three calls/minute on average, including profiles/retries. Proxy runner wall time is not an app freshness measurement.
- Real phone checks remain required for direction/mirroring, crop/orientation, advice before readiness, expired/changed reference, local-only/offline, manual and automatic capture.

The harness reports manifest correctness separately from these behavioral gates. Passing mocked tests does not demonstrate reference understanding.
