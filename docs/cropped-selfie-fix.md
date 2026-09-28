# Cropped selfie assessment fix

The supplied landscape selfie was diagnosed locally with Vision. It returned one face, one person rectangle, and no body pose. The person rectangle extended below the image (`minY = -0.0036271811`). Reference extraction rejected any rectangle outside the unit image bounds, even though the visible face was valid.

Reference and live ingestion now intersect finite, positive detector rectangles with the visible image bounds. Invalid or wholly offscreen boxes still invalidate evidence; subject counts and association checks remain intact. Raw rectangle dimensions are checked so negative dimensions cannot pass through CGRect's standardized width/height accessors.

Regression tests use only measured coordinates, not the user's photo. They cover the reported selfie, clipped faces, invalid boxes, and additional subjects. Face-only evidence supports framing but cannot assert pose alignment or independently trigger automatic capture. Finger/peace-sign recognition is unchanged.

Validation:

- Red regression run reproduced `noPoseDetected` using the measured coordinates.
- Focused green run: 12 tests passed across four suites.
- Independent code review: no findings.
- Full simulator run: 781 tests in 91 suites passed, `TEST SUCCEEDED` (`/tmp/picpal-clipping-full.xcresult`).

The diagnostic used macOS Vision; these results establish the boundary-handling bug, not identical detector behavior on every iPhone. Real-phone assessment with the same photo remains the final product check.

## Follow-up: incorrect multiple-person warning

Live face/person association failure previously assigned `subjectCount = 2`, even when each detector reported exactly one subject. It now preserves measured counts and marks conflicting evidence unavailable. The coordinator clears matching history rather than asserting another person is present. Real multiple detections still block matching and capture.

The production live monitor also filtered out cropped boxes before the earlier clipping fix could run. Confidence filtering now preserves those boxes for shared validation and clipping. The diagnostics panel shows individual detector counts and association validity for future live investigation.

Failing regressions reproduced the fabricated count and warning. Full validation passed 785 tests in 91 suites (`/tmp/picpal-single-subject-full.xcresult`); independent review found no issues. A temporary simulator diagnostic found one MediaPipe body in the supplied image, but simulator Vision inference was unavailable. That diagnostic was removed. These fixes do not establish which detector result triggered the user's live warning or eliminate model false positives from background photos.
