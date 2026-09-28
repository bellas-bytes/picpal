# Selfie reference and image orientation correction

User reports that a selfie reference intermittently produces “Bring the person into view” and expects portrait/landscape photo recognition. Goal: reference-aware framing that accepts a clearly visible face without requiring hips/full body, and consistent portrait/landscape image, preview and capture geometry. User's autonomous implementation/review/install preference persists.

Confirmed causes: ReferenceSession guards body landmarks before face detection; SubjectObservationMonitor publishes presence only via full-person rectangles; comparator requires full torso and treats personBox nil as absence. Reference overlay is aspect-fit while target geometry is compared as full image coordinates against a fixed 3:4 preview. Camera preview, buffers, photo output and supported UI orientations are hard-coded portrait.

## Subject evidence

Detect face evidence independently from body success in reference and live paths. One credible face may establish presence for a close-up reference even when no body pose is extracted. Carry face bounds explicitly; never compare face dimensions to full-body bounds. Select a stable framing domain from the reference: face for close-up/cropped selfie without supported torso, person for body references. Reject multiple or unassociated subjects and weak/nonfinite detections. Inference failure in body tracking must not discard valid face detection; actual face-detection failure remains unknown. Keep individual joint confidence and full-match restrictions.

Face-only references can provide face position/scale framing advice and honest alignment captions without telling users to reveal missing hips/legs. Face framing does not prove body pose or semantic match; it must not silently enable automatic full-reference capture. Full-body references still ask for the required body view rather than switching comparison domain when the person is temporarily occluded. Add a short bounded presence grace only if justified by tests; never reuse stale match/capture evidence.

## Orientation and displayed geometry

Classify portrait, landscape or square from upright display dimensions, honoring UIImage/EXIF orientation. Do not claim historical camera orientation if that metadata is unavailable. Display reference format unobtrusively. Normalize once for consistent reference analysis; test rotated non-square and mirrored images using asymmetric pixels.

Support phone portrait and both landscape directions with one shared orientation state for preview, physically upright analysis buffers and still-photo output. Unknown/flat device readings retain last valid orientation. Enable corresponding app orientations and adapt control layout so shutter/flip/reference remain reachable in landscape. Stop auto-capture, clear prior geometry/match/audio and restart tracking on orientation change. Preserve camera flip with reference and existing mirror identity handling. Tilt interpretation must treat a correctly held landscape phone as level rather than 90 degrees tilted.

Reference aspect-fit overlay and comparator must use the same fit transform within actual preview viewport. Preview aspect updates with capture orientation (3:4 portrait, 4:3 landscape) and is passed instead of the hardcoded ratio. Do not stretch or reinterpret a landscape reference as portrait. A mismatch can show a rotate-phone hint without repeatedly declaring the subject absent. Preserve manual capture and consent/cloud behavior.

## Verification and rollout

Regression tests: face-only reference/live pair with no body produces framing evidence, never missing-person; no-face/no-body reports missing; multiple subjects and detector errors safe; person/face box-domain mismatch cannot match; full-body regressions and stale behavior preserved. Orientation tests cover EXIF right/left, landscape sides, flat/unknown device retention, angle offsets, reference aspect-fit alignment, mirror semantics and control availability. Run full Swift suite and independent review, then signed device build/install/relaunch on paired iPhone as continuation of user testing. Device sensor accuracy and live visual quality still require the user's check.
