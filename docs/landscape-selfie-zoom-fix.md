# Landscape rotation and selfie zoom

The user clarified that landscape means physically rotating the phone sideways.

Preview orientation now follows its hosting window scene after layout, rather than relying solely on device notifications that can arrive before the interface rotates. Capture buffers, photos and motion coaching receive the same semantic orientation. Preview mirroring and orientation are reapplied after session startup and camera input changes, when the connection may be created after SwiftUI's previous update. Foreground entry also resynchronizes orientation.

Both startup and camera switching prefer the ultra-wide front camera when available, falling back to the standard front camera. This follows Apple's [Center Stage front-camera documentation](https://developer.apple.com/videos/play/wwdc2026/341/). No dynamic sensor aspect-ratio feature or automatic Center Stage framing was added.

The slider exposes the hardware minimum instead of a hard-coded 1.0, and its label uses the hardware's display multiplier. A widest-selfie button remains available with references. Reference coaching suggests available zoom-out before physical movement; once the camera is at its actual minimum, it says to hold the phone farther away. It never fabricates a wider optical range.

Independent review caught and resolved a separate camera-switch selection path; both paths now use one helper. Review found no remaining actionable issues. Regression coverage includes both scene landscape directions, transient unknown orientation, hardware zoom ranges/display scale, and selfie advice at/above minimum zoom.

Full simulator validation: **807 tests in 94 suites passed**, `TEST SUCCEEDED` (`/tmp/picpal-rotation-zoom-full.xcresult`).

Physical rotation, the detected front-camera type and its actual field of view still require the installed iPhone build to be exercised. Simulator tests cannot establish these hardware behaviors. System orientation lock remains respected.

## Follow-up: camera startup crash

The first installed build crashed on its camera session queue. The device crash report showed `swift_task_checkIsolatedSwift` inside the Combine notification sink in `CameraPreviewView.Coordinator.attach`. That closure inherited MainActor isolation, but NotificationCenter invoked it synchronously on the background posting queue; the nested MainActor Task could not run before the isolation assertion.

The sink is now explicitly `@Sendable`, leaving the existing MainActor Task responsible for UI work. A real background-post regression reproduces the original crash and covers both connection-change and session-start notifications while retaining the coordinator. The red run failed with the crash; the fixed full suite passed **808 tests in 95 suites** (`/tmp/picpal-launch-fixed-full.xcresult`). Independent source review approved the fix.

The corrected signed build was installed and launched with device console logging. Camera startup and subsequent front/back connection changes completed without the previous trap. A later device process query confirmed PicPal remained running (PID 62544). Evidence: `/tmp/picpal-launch-fixed-phone.log` and `/tmp/picpal-fixed-process.json`.

## Follow-up: camera switch rotation/flip transition

The previous synchronous camera switch published the desired position before its input swap ran. SwiftUI could apply front-camera mirroring to the old back-camera connection. The replacement API returns the actual position asynchronously after configuration commit and callback-queue drain; failed/unavailable switches preserve position. Preview mirroring uses the connected input port, and orientation/mirroring setters disable implicit animations and skip unchanged values.

The UI hides the preview during the switch, blocks repeated switch/capture/zoom actions, then refreshes and reveals the committed connection. Analysis frames are gated during configuration; reference geometry is invalidated before and after the switch. No fixed-delay animation was added. A queue drain does not prove that the first rendered sensor frame is from the new camera, so perceived smoothness still requires a phone check.

Core/UI changes were cross-reviewed between root and the implementation agent; a third reviewer could not start because of the session's agent-thread limit. Full verification passed **809 tests in 95 suites** (`/tmp/picpal-switch-transition-full.xcresult`), including committed-position failure semantics, preview hiding without animation, and the earlier background-notification crash regression.

## Follow-up: arm's-length selfie framing

A physical iPhone 17 diagnostic on 2026-09-24 measured the selected front camera as `builtInUltraWideCamera`, active format 4032×4032, reported format field of view 84.08°, raw zoom 1.0 and minimum available zoom 1.0, with Center Stage inactive. Its delivered upright analysis buffers were 1608×2144, matching the portrait 3:4 preview. The default dynamic sensor aspect ratio was 4:3; raw sensor dimensions alone therefore do not establish a preview crop. Evidence: `/tmp/picpal-fov-before-phone.log`.

These measurements establish that the installed configuration is already at its active format's minimum zoom. They do not establish visual parity with Apple's Camera app. A smaller displayed zoom number would not widen the hardware view. The landscape reference also has a smaller target face height when fitted inside the portrait preview, so exact reference framing can remain unreachable at arm's length.

The follow-up coaching change permits face-relative head/hand comparison when a front camera is ready, settled, and at its measured minimum zoom, and the outstanding face-framing correction would be `move_back`. Other framing corrections and body references retain their existing ordering. The framing dimension stays different and partial selfie pose stays unknown, preserving the automatic-capture gate. At minimum, selected local or cloud `move_back` captions instead acknowledge the widest selfie view. Above minimum they continue to suggest zooming out. Hardware readiness/minimum-state changes also refresh cached local comparison.

Independent code review approved this bounded change. Temporary front-camera launch overrides and frame-format diagnostic logging were removed before the final build. No unsupported zoom range or new dynamic sensor aspect ratio was introduced.

Final verification: **814 tests in 95 suites passed**, `/tmp/picpal-selfie-minimum-full.xcresult`; signed device build succeeded. Installed on the connected iPhone (`A0D24DEE-A120-432B-8642-C1BB45EC0C11`) and launched successfully with camera/inference startup in `/tmp/picpal-selfie-minimum-phone.log`. Visual comparison against Apple's widest selfie framing remains unverified.

## Follow-up: physical landscape rotation

Previously the app only consumed UIKit's current interface orientation. When the scene stayed portrait, capture also stayed portrait; physical device notifications could not change this because the foreground scene always took precedence. The fix preserves scene orientation as the shared geometry source but actively requests the scene follow a stable physical hold using [UIKit's scene geometry API](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)).

The existing CoreMotion stream now recognizes raw gravity near portrait or either landscape direction after 0.25 seconds. Flat, invalid, upside-down and intermediate readings do not request rotation. Requests target the preview's hosting scene and wait during modal presentation, background state, capture and camera switching. The existing screen update loop drains deferred requests; repeated rejected requests for the same direction are suppressed. Preview mirroring, animation suppression, photo orientation and analysis orientation retain their existing shared scene behavior. Actual UIKit acceptance under portrait lock requires a physical-phone check; DEBUG logs distinguish requests, applied orientations and rejections.

Independent review approved the implementation, including deferred requests after dismissing the reference picker. Focused tests passed 23 tests across four suites.

Full verification passed **820 tests in 97 suites**, `/tmp/picpal-physical-rotation-full.xcresult`. Signed build succeeded and was installed on the connected iPhone (`20CECD0D-008C-4937-9905-CF244EBFDE85`). Device console `/tmp/picpal-physical-rotation-phone.log` records a physical landscapeRight request while the scene was portrait, followed by `Applied scene capture=landscapeRight`, front-camera connection rotation 270°, then a return to portrait/0°. This confirms physical front-camera landscape and portrait transitions on the device; orientation-lock setting and visual overlay alignment were not independently observed.

## Follow-up: clipped layout and black preview after rotation

The user's screenshot disproved the prior visual-success assumption: scene orientation changed in logs, but the viewport and controls were oversized/clipped, with no visible live preview. The previous root layout put separate camera subtrees in portrait and landscape branches, recreating the preview-layer owner during rotation. The viewport also relied on an aspect-ratio proposal around overlay content without explicit fitted bounds.

`CameraStage` now uses one stable preview subtree under `AnyLayout`, with explicit dimensions fitted to the available screen area after reserving controls. This prevents overlay content from determining viewport size and avoids replacing the camera preview layer when switching between portrait and landscape. The rendering regression hosts the real preview representable and reference overlay, with a landscape fixture, and checks the same UIView survives portrait → landscape → portrait within the supplied bounds. Simulator rendering can validate layout and identity but cannot prove physical camera-frame delivery.

The corrected standalone render fixture passed, with the preview at `(0,0,393,524)` in portrait and `(17.33,0,453.33,340)` in landscape. Root inspected all three PNGs; the full viewport and capture controls fit. Inspection also caught the reference-orientation badge overlapping zoom controls; badge-only bottom padding now separates them without modifying the reference-image transform. Independent code review approved both changes.

Final layout validation passed **821 tests in 98 suites** (`/tmp/picpal-stage-full.xcresult`), including preview/session identity and rendered bounds. Final landscape PNG inspection confirmed the reference badge is clear of zoom controls. Signed build succeeded, installed on the phone (`1975BC18-6C2D-4641-9C6E-58F04C39310E`) and launched; console `/tmp/picpal-stage-phone.log`. Live visual confirmation remains a phone check, not established by orientation logs.
