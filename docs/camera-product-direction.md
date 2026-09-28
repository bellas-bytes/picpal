# PicPal: a usable camera with subject-aware coaching

Status: approved and implemented for personal-device validation, based on device testing feedback. The user has selected still photography only: video, Live Photos, and portrait effects are not required. The user wants automatic camera adjustments so coaching can focus on physical positioning. The still camera implementation is covered in device-readiness.md; remaining ideas below are product direction rather than verified device behavior.

## Product direction

PicPal should let someone compose, take, and save a photograph in one app. Coaching should understand the intended shot and give the next useful adjustment. Basic alignment warnings alone do not meet that need.

## iOS integration choices

- **Build PicPal's camera with AVFoundation (recommended).** Keep access to live frames for analysis and add ordinary camera controls to the existing capture session. Support available hardware features through capability checks.
- **Embed Apple's camera picker.** UIImagePickerController supports a custom overlay inside PicPal, but it is not the separate Camera app and does not expose a public continuous-frame callback for the existing analysis pipeline. It is a poor fit for this live coach.
- **Overlay Apple's separate Camera app.** There is no supported Camera-app extension point for this. Lock Screen camera extensions launch the developer's own capture experience; they do not inject UI into Apple's Camera app.

Do not promise identical features or processing to Apple's Camera. Evaluate video, Live Photos, depth/portrait effects, Night mode, and other advanced modes separately instead of presenting them as automatically included.

## Proposed coaching flow

1. **Choose the intended shot:** full-body person, closer portrait, or general photo. In general-photo mode, absence of a person is not an error.
2. **Find the person:** show “Looking for a person.” After sustained absence, say “I can't see a person yet.” Do not repeat every frame. Distinguish a detection failure or unavailable analyzer from confirmed absence.
3. **Adjust distance and crop:** use the person's frame coverage and visible landmarks relative to the chosen shot. For full body, prioritize leaving room around the head and feet; for a closer portrait, intentional lower-body cropping is allowed. Say “Move closer” or “Step back” only when supported by the detection.
4. **Refine framing and light:** offer the highest-impact remaining improvement. Centered portraits should not automatically be treated as bad composition. Minor tilt remains tolerated.
5. **Confirm readiness:** show a short positive status when the shot is usable. The shutter remains available regardless of coaching state.

Use framing-based relative distance initially. Do not display meters or feet inferred solely from a person's bounding box: body size, pose, lens, and zoom change that relationship. The chosen shot type and active zoom must influence the framing target.

## Proposed camera baseline

- Still-photo shutter using a photo output, independent of the low-resolution analysis frames.
- Save to Photos with an appropriate permission request and visible success/failure feedback.
- Front/rear switching and supported zoom/lens controls.
- Tap focus/exposure and exposure adjustment, preserving existing functionality.
- Flash modes where supported, timer, and recent-photo preview.
- Accessible voice toggle and a compact coaching caption that does not obscure the subject or camera controls.

Video, Live Photos, and portrait effects are outside the selected scope.

## Automatic camera assistance

Proposed default: automatically focus and meter exposure on the selected person, use automatic white balance, and make conservative, smooth zoom adjustments toward the chosen shot's framing target. Automatic adjustment is capability-checked and bounded; a manual override suspends the corresponding automatic control.

- Establish a stable subject and shot type before adjusting zoom. If detection is uncertain or absent, stop zoom adjustments instead of chasing noise or a different subject.
- During physical-distance coaching, hold zoom steady so it does not cancel the user's movement. Once the user settles, make a small final zoom adjustment only if appropriate.
- Prefer asking for a physical-distance change when more zoom would harm image quality or when perspective needs to change. Zoom changes frame coverage, while camera-to-subject distance changes perspective; they are not interchangeable.
- Let exposure settle before judging whether the remaining lighting issue needs a physical action. Avoid repeated bright/dark oscillation and large automatic exposure jumps.
- Automatic exposure can alter recorded brightness, but cannot relocate a light source, remove harsh shadows, or guarantee a clean image in insufficient light. Coaching may still need to say “Turn toward the window” or “Find more light.”
- Keep the shutter available and avoid automatic zoom or exposure corrections that conflict with capture. Provide an understandable Auto/manual state.

Precise hardware settings do not imply an objectively perfect composition. Evaluate the chosen framing targets and adjustment limits on the actual phone before calling them reliable.

## Engineering gaps confirmed in the current project

- `CueEvaluator` ignores `.noSubject`; absence is not surfaced as actionable coaching.
- Saliency framing and person detection are different signals. A salient object must not count as finding a person.
- Generic tilt, blur, and exposure cues precede body guidance in the current priority chain.
- There is no general shot-dependent distance coaching state or still-photo capture/save flow.
- The scene gate discards unchanged frames before the analysis pipeline. Subject presence and distance need fresh observations at a bounded cadence even when framing is steady; missing/expired results must not leave stale advice active.

## Acceptance checks for implementation

- In person mode, an empty scene produces an absence state after a short stable interval; a person entering the frame clears it.
- Looking away from a person clears distance/framing advice rather than retaining the last person's box.
- Full-body and closer-portrait modes produce different distance guidance for the same crop.
- Detection jitter does not alternate contradictory commands.
- Small tolerated tilts do not preempt finding a subject or improving distance.
- Captured photos save successfully, retain correct orientation, and do not use downscaled analysis buffers as the photo.
- Capture, zoom, camera switching, permission denial, and save failures have visible, recoverable behavior.

## Apple references

- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)
- [UIImagePickerController and overlays](https://developer.apple.com/documentation/uikit/uiimagepickercontroller)
- [LockedCameraCapture](https://developer.apple.com/documentation/lockedcameracapture)
- [Capturing still and Live Photos](https://developer.apple.com/documentation/avfoundation/capturing-still-and-live-photos)
