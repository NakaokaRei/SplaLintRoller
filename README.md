# SplaLintRoller

An iOS AR prototype that tracks a lint roller without attached markers and visualizes its estimated cleaning path as ink on the floor.

## Getting started

1. Open `SplaLintRoller.xcodeproj` in Xcode and configure your signing team.
2. Select a physical iPhone with LiDAR running iOS 26.5 or later, then build and run. The minimum OS version is unchanged from the original project settings.
3. Allow camera access. Slowly move the camera over a well-lit floor, then tap the floor to select it.
4. Place the roller on the floor and tap **Select roller**. On the frozen image, drag a rectangle around the adhesive roller head only, then tap **Track this area**. Keep the iPhone and roller as still as possible while selecting.
5. Check that the green tracking box and yellow contact-point marker align with the roller. Set the paint width to match your roller, then tap **Start painting**.
6. Tap **Pause** before lifting the roller. Brief tracking uncertainty pauses ink output while the same Vision sequence continues. If it becomes stable within the grace period, painting continues from a new stroke when it was previously active. If tracking is lost for longer, use **Select roller again**, then tap **Start painting**.

The app currently uses Japanese UI labels. The English button names above are translations of those labels.

The app supports portrait orientation only. The simulator and devices without LiDAR show an explanation instead of the AR experience. Camera images are not saved to files or transmitted over the network, and cleaning history is not stored. Backgrounding or interruptions stop painting. After the floor is recovered, select the roller again and resume manually. If the floor coordinate system cannot be recovered within eight seconds, or the selected floor anchor is removed, the ink is cleared and you must select the floor again.

## Architecture

- `RollerSession`: Camera permission, AR session lifecycle, floor selection, frozen frames, UI state, and stopping on failures.
- `RollerTracker`: Runs Vision tracking serially inside an actor. New frames are skipped while one frame is being processed. Generation tokens discard delayed results from an earlier selection.
- `TrackingTolerance`: Centralizes confidence, viewport visibility, result freshness, and the short tracking grace period. There is no template storage or automatic rediscovery.
- `TrackingGeometry` / `StrokeBuilder`: Converts Vision's bottom-left coordinates into AR viewport coordinates, constructs rays using the camera pose at the frame's timestamp, and interpolates or breaks strokes.
- `InkRenderer`: Anchors ink to the selected floor and renders strips in floor-local coordinates, batching 128 segments per mesh. Rendering stops at 12,000 segments.
- `SceneOcclusion` / `OcclusionGeometry`: Renders reconstructed non-floor surfaces as depth-only occluders. Mesh updates are queued and processed in bounded batches.
- `LiveDepthOcclusion` / `DepthOcclusionBuilder`: Builds a fresh camera-space occlusion mesh from per-frame LiDAR depth for moving objects such as the roller. Geometry processing runs on a separate actor.

Unrotated camera images are passed to Vision with orientation `.up`. The selection coordinates and frozen image use the same `ARFrame.displayTransform` so portrait rotation and aspect-fill cropping match. The bottom-center point of the on-screen tracking box is projected onto the selected floor. This estimates a contact point; it does not measure the roller surface's depth or detect physical contact.

The app enables LiDAR `sceneDepth` and uses ARKit's horizontal plane detection and raycasting. Scene depth also supplies the moving-object occlusion mesh described below. It does not perform custom contact estimation from the depth map. Lifting the roller does not automatically stop painting, so you must pause manually.

## Tracking tolerance

Automatic template-based rediscovery has been removed following unsuccessful user testing. The app now keeps the existing Vision sequence alive through brief uncertainty instead of immediately requiring another selection.

- Minimum Vision confidence is **0.45**, lowered from 0.6. Lower-confidence results are neither painted nor fed back as the next requested tracking box.
- The box may touch or slightly cross the viewport edge if at least **80%** remains visible and its bottom-center contact point is still on screen.
- Results up to **0.5 seconds** old are accepted, increased from 0.35 seconds.
- A maximum **0.75-second grace period** is measured from the last valid sample. Temporary low confidence, a missing floor hit, an AR camera tracking fluctuation, or an analysis error holds ink output without restarting Vision. Bad samples do not extend the deadline.
- During the grace period, the UI shows that it is waiting for tracking. Ink is held immediately and the stroke is broken. If tracking stabilizes in time, painting continues only if the user had left it active. Manually pausing remains effective.
- When the grace period expires, painting stops and the roller must be selected again. No image search or automatic re-identification runs.

The 3 m range limit and guards against sudden position jumps remain in place. Stroke samples still reject changes over 25 cm or approximately 1.5 m/s with a 2.5 cm allowance. Long sample gaps break the stroke rather than filling in unobserved movement. Backgrounding and AR session interruptions require reselection; the short grace period does not apply across those lifecycle events.

These are initial tuning values. Relaxing confidence may increase drift onto the floor, a hand, or a similar object. Check the yellow marker and pause or reselect if it no longer follows the roller. Physical-device tracking continuity with these settings has not yet been verified.

## Occlusion

On supported devices, `personSegmentationWithDepth` lets detected people in front of the floor hide the ink behind them. The depth relationship is used, rather than drawing every person over all virtual content.

LiDAR scene reconstruction supplies meshes for other real surfaces, such as furniture. These are rendered with `OcclusionMaterial`. The built-in whole-scene mesh occlusion option is disabled because a noisy reconstructed floor can hide ink just above it. The custom mesh excludes faces classified as floor and remaining triangles whose vertices all lie within 2.5 cm of the selected floor plane. Other faces remain depth-only occluders.

For the moving roller, the app additionally builds a depth-only mesh from the latest raw `sceneDepth` map, rather than relying solely on accumulated scene reconstruction. This runs at most 20 times per second with one frame in flight. The sampled grid is bounded to 128 columns. Depth is unprojected with the camera intrinsics and rendered with the camera transform from the same frame.

Only samples with medium or high depth confidence, within 0.1–3 m, and at least 1.5 cm above the selected floor participate. Triangles are omitted across invalid samples or depth differences greater than 8 cm. This keeps measured floor pixels from hiding the ink and avoids filling gaps between separate objects. Depth older than 120 ms is hidden; missing data, floor changes, and interruptions invalidate the live mesh. Raw depth is used instead of temporally smoothed depth to reduce moving-object trails.

This makes the intended ordering **camera → person or foreground object → ink → floor**. Ink remains 3 mm above the selected floor. People segmentation and LiDAR depth are estimates: edges can flicker, very low surfaces are intentionally excluded, and thin or fast-moving roller parts may still be missed. Physical-device visual accuracy and frame rate have not yet been verified. Occlusion changes visibility only; it does not determine whether the roller is touching or cleaning the floor.

## Testing

Unit tests cover coordinate round trips, portrait contact-point conversion, camera rays, reverse-direction selection, stroke interpolation, back-and-forth motion, small movements, stroke breaks after pauses, sudden jumps, update gaps, and invalid coordinates. Additional tests cover confidence and visibility thresholds, short uncertainty versus sustained loss, stale results, stroke separation during the grace period, floor exclusion, and depth-only mesh creation. Live-depth tests cover a raised roller surface versus the floor, camera intrinsics, triangle winding, invalid or low-confidence samples, depth boundaries, and stale data. UI tests check the unsupported-device explanation on the simulator.

```sh
xcodebuild -project SplaLintRoller.xcodeproj -scheme SplaLintRoller \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test
```

### Physical-device acceptance checks — not yet performed

- Grant and deny camera permission, then verify recovery after enabling access in Settings.
- Select a floor and confirm that the frozen-image selection and live tracking box enclose the same roller.
- Confirm that the yellow marker approximately follows the actual contact point **before painting**.
- Move slowly along a 1 m straight path, back and forth, and through a 90-degree turn. Check that the path stays continuous and remains on the floor when the camera moves.
- Test stopping when the roller leaves the frame, is hidden by a hand, moves abruptly, or crosses a dark floor. Check that brief uncertainty holds ink output without immediately losing the sequence, while sustained loss requires reselection. Confirm that neither case creates a connecting line across unobserved movement.
- Check that pausing or holding still does not add unwanted ink. Test width adjustment and clearing all ink.
- Verify that returning from the background or a camera interruption requires roller reselection and manual painting resumption, and that failure to recover the same floor resets the ink.
- Move a person or foot in front of painted floor and confirm that the ink appears behind them. Check that the unobstructed ink remains visible on the floor.
- Move the camera around furniture and check depth occlusion, including boundary flicker and mesh-update delay. Test a moving roller separately: its surface should hide the ink, and moving it away should reveal the ink immediately without a lingering hole. Check thin edges and fast movement as well as stationary alignment.
- Record tracking stability with a white roller on a white floor, carpet, and reflective flooring.
- Use the app for several minutes and check rendering responsiveness, device heat, and memory usage.

Position accuracy, occlusion detection rate, and continuous tracking duration on physical devices have not been measured. Passing automated tests or building successfully does not establish reliable tracking of a real lint roller.
