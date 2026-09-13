# SplaLintRoller

An iOS AR prototype that tracks a lint roller without attached markers and visualizes its estimated cleaning path as ink on the floor.

## Getting started

1. Open `SplaLintRoller.xcodeproj` in Xcode and configure your signing team.
2. Select a physical iPhone with LiDAR running iOS 26.5 or later, then build and run. The minimum OS version is unchanged from the original project settings.
3. Allow camera access. Slowly move the camera over a well-lit floor, then tap the floor to select it.
4. Place the roller on the floor and tap **Select roller**. On the frozen image, drag a rectangle around the adhesive roller head only, then tap **Track this area**. Keep the iPhone and roller as still as possible while selecting.
5. Check that the green tracking box and yellow contact-point marker align with the roller. Set the paint width to match your roller, then tap **Start painting**.
6. Tap **Pause** before lifting the roller. If tracking is lost, bring the roller back into view and hold it briefly on the floor. The app searches for it automatically. Once the yellow marker returns, tap **Start painting** to resume. **Select roller again** remains available if automatic recovery cannot find it.

The app currently uses Japanese UI labels. The English button names above are translations of those labels.

The app supports portrait orientation only. The simulator and devices without LiDAR show an explanation instead of the AR experience. Camera images are not saved to files or transmitted over the network, and cleaning history is not stored. Backgrounding or interruptions stop painting. After the floor is recovered, the app searches for the previously selected roller again, provided its appearance template is available. If the floor coordinate system cannot be recovered within eight seconds, or the selected floor anchor is removed, the ink is cleared and you must select the floor again.

## Architecture

- `RollerSession`: Camera permission, AR session lifecycle, floor selection, frozen frames, UI state, and stopping on failures.
- `RollerTracker`: Runs Vision tracking and appearance-based recovery serially inside an actor. New frames are skipped while one frame is being processed. Generation tokens discard delayed results from an earlier selection or recovery attempt.
- `TemplateRecovery` / `RecoveryConfirmation`: Searches the visible camera image for the original appearance and requires three consistent observations before accepting a match.
- `TrackingGeometry` / `StrokeBuilder`: Converts Vision's bottom-left coordinates into AR viewport coordinates, constructs rays using the camera pose at the frame's timestamp, and interpolates or breaks strokes.
- `InkRenderer`: Anchors ink to the selected floor and renders strips in floor-local coordinates, batching 128 segments per mesh. Rendering stops at 12,000 segments.
- `SceneOcclusion` / `OcclusionGeometry`: Renders reconstructed non-floor surfaces as depth-only occluders. Mesh updates are queued and processed in bounded batches.

Unrotated camera images are passed to Vision with orientation `.up`. The selection coordinates and frozen image use the same `ARFrame.displayTransform` so portrait rotation and aspect-fill cropping match. The bottom-center point of the on-screen tracking box is projected onto the selected floor. This estimates a contact point; it does not measure the roller surface's depth or detect physical contact.

The app enables LiDAR `sceneDepth` and uses ARKit's horizontal plane detection and raycasting. It does not perform custom contact estimation from the depth map. Lifting the roller does not automatically stop painting, so you must pause manually.

Initial stopping conditions include Vision confidence below 0.6, the tracking box reaching a viewport edge, no raycast hit on the selected floor, distance exceeding 3 m, a position change exceeding 25 cm between samples or approximately 1.5 m/s with a 2.5 cm allowance, an update gap exceeding 0.5 seconds, or analysis results more than 0.35 seconds old. These are conservative starting values for tuning on a physical device. Tracking can drift onto another object even with high confidence, so check the position indicator.

## Automatic tracking recovery

**Known issue:** Initial user testing reports that tracking does not recover successfully. The current implementation is a prototype; passing synthetic-image tests has not established reliable recovery during actual cleaning.

The first selection stores a small luminance template in memory, including a narrow border around the roller to preserve its outline. The reference appearance is not updated from later frames, so a hand or another object cannot replace it during occlusion.

When tracking fails, painting stops and the stroke is broken. At most four times per second, a bounded coarse-to-fine search compares the template against the visible raw camera image using normalized correlation. It searches at multiple sizes based on the original and last accepted tracking boxes. Low-contrast matches and competing candidates with similar scores are rejected. Three consistent observations on distinct frames are required before restarting Vision. The candidate must also pass the usual floor-projection checks before painting can be enabled.

Recovery does **not** fill in the path traveled while the roller was hidden, and it does not resume painting automatically. Check the marker, then tap **Start painting**. A floor reset discards the recovery reference; ordinary tracking loss, backgrounding, and interruptions preserve it.

This is appearance matching, not a trained lint-roller detector. Large rotations, major viewpoint changes, a different-looking background around the roller, featureless white surfaces, or multiple similar rollers can prevent recovery. If the initial selection has insufficient contrast, normal Vision tracking remains available but recovery requires a new selection. Use **Select roller again** as the fallback. Recovery accuracy and latency on a physical device are not yet measured.

## Occlusion

On supported devices, `personSegmentationWithDepth` lets detected people in front of the floor hide the ink behind them. The depth relationship is used, rather than drawing every person over all virtual content.

LiDAR scene reconstruction supplies meshes for other real surfaces, such as furniture. These are rendered with `OcclusionMaterial`. The built-in whole-scene mesh occlusion option is disabled because a noisy reconstructed floor can hide ink just above it. The custom mesh excludes faces classified as floor and remaining triangles whose vertices all lie within 2.5 cm of the selected floor plane. Other faces remain depth-only occluders.

This makes the intended ordering **camera → person or foreground object → ink → floor**. People segmentation and reconstructed meshes are estimates: edges can flicker, scene meshes update less quickly than moving objects, and small or fast-moving roller parts may not occlude accurately. Occlusion changes visibility only; it does not determine whether the roller is touching or cleaning the floor.

## Testing

Unit tests cover coordinate round trips, portrait contact-point conversion, camera rays, reverse-direction selection, stroke interpolation, back-and-forth motion, small movements, stroke breaks after pauses, sudden jumps, update gaps, and invalid coordinates. Additional tests cover rediscovery after translation and scale changes, absent or ambiguous candidates, recovery confirmation, floor exclusion, and depth-only mesh creation. UI tests check the unsupported-device explanation on the simulator.

```sh
xcodebuild -project SplaLintRoller.xcodeproj -scheme SplaLintRoller \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' test
```

### Physical-device acceptance checks — not yet performed

- Grant and deny camera permission, then verify recovery after enabling access in Settings.
- Select a floor and confirm that the frozen-image selection and live tracking box enclose the same roller.
- Confirm that the yellow marker approximately follows the actual contact point **before painting**.
- Move slowly along a 1 m straight path, back and forth, and through a 90-degree turn. Check that the path stays continuous and remains on the floor when the camera moves.
- Test stopping when the roller leaves the frame, is hidden by a hand, moves abruptly, or crosses a dark floor. Bring the roller back into view without taking another capture, confirm automatic rediscovery, and check that resuming does not create a long connecting line.
- Check that pausing or holding still does not add unwanted ink. Test width adjustment and clearing all ink.
- Verify that returning from the background or a camera interruption searches for the previous roller and requires manual painting resumption, and that failure to recover the same floor resets the ink.
- Move a person or foot in front of painted floor and confirm that the ink appears behind them. Check that the unobstructed ink remains visible on the floor.
- Move the camera around furniture and check depth occlusion, including boundary flicker and mesh-update delay. Test a moving roller separately; scene meshes may not keep up.
- Put two similar rollers in view and check that ambiguous recovery stays paused.
- Record tracking stability with a white roller on a white floor, carpet, and reflective flooring.
- Use the app for several minutes and check rendering responsiveness, device heat, and memory usage.

Position accuracy, occlusion detection rate, and continuous tracking duration on physical devices have not been measured. Passing automated tests or building successfully does not establish reliable tracking of a real lint roller.
