# Thumbnail Grid Zoom Animation - Investigation Notes

## Goal

Implement a cross-fade zoom animation for the thumbnail grid where:
- **Old view** scales (zooms in direction of change) while fading out
- **New view** fades in with the correctly reflowed layout

This would provide a more polished UX similar to Photos.app when using +/- buttons or pinch gesture to change thumbnail size.

## Current Behavior

The zoom transition works but without the scale animation:
1. Old view instantly disappears
2. New layout fades in

The fade-in works correctly; the scale animation does not.

## Approaches Attempted

### Attempt 1: NSAnimationContext with layer transform

```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.25
    ctx.allowsImplicitAnimation = true
    overlay.animator().alphaValue = 0.0
    overlay.animator().layer?.setAffineTransform(scaleTransform)
}
```

**Result:** Transform executes immediately (no animation), only alpha animates.

**Root cause:** `NSAnimationContext.animator()` only animates NSView properties (frame, bounds, alphaValue). It does NOT animate CALayer properties. Calling `overlay.animator().layer?.setAffineTransform()` bypasses the animation proxy entirely.

### Attempt 2: CABasicAnimation for layer transform

```swift
let transformAnim = CABasicAnimation(keyPath: "transform")
transformAnim.fromValue = CATransform3DIdentity
transformAnim.toValue = CATransform3DMakeAffineTransform(scaleTransform)
transformAnim.duration = 0.25
transformAnim.fillMode = .forwards
transformAnim.isRemovedOnCompletion = false

overlayLayer.add(transformAnim, forKey: "zoomTransform")
```

**Result:** No visible animation. Overlay disappears, new view fades in.

**Possible causes:**
- NSImageView's layer management may interfere with direct CALayer animations
- Layer may not be fully realized when animation is added
- View system may be resetting layer properties

### Attempt 3: NSView frame animation

```swift
// Calculate scaled frame from center
let targetFrame = CGRect(x: newX, y: newY, width: newWidth, height: newHeight)

NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.25
    ctx.allowsImplicitAnimation = true
    overlay.animator().frame = targetFrame
    overlay.animator().alphaValue = 0.0
}
```

Used plain NSView with snapshot as layer contents instead of NSImageView.

**Result:** No visible scale animation. Same symptom as previous attempts.

**Possible causes:**
- Frame animation may not be working as expected on dynamically created views
- Auto Layout constraints may be interfering
- The view may need to be in the hierarchy longer before animating

## Ideas for Future Investigation

1. **Use NSViewAnimation** - Older but reliable API for NSView animations that might handle frame changes better

2. **Try CAAnimationGroup** - Combine transform and opacity in a single animation group added to a dedicated CALayer (not backing an NSView)

3. **Standalone CALayer approach** - Create a pure CALayer (not view-backed) for the snapshot overlay, add it as sublayer to the container's layer, animate directly

4. **Core Animation implicit animations** - Remove `CATransaction.setDisableActions(true)` and let CA handle implicit animations on the overlay layer

5. **NSWindow-level overlay** - Create a child window with the snapshot, animate the window's frame (windows animate reliably)

6. **Debug with CA_DEBUG_TRANSACTIONS** - Set environment variable to see what Core Animation is actually doing

7. **Check if layoutSubtreeIfNeeded** - Is triggering something that removes/resets the overlay

8. **Delay animation start** - Use DispatchQueue.main.async to ensure view is fully in hierarchy before starting animation

## File Location

Animation code is in:
- `SoftBurn/Views/Grid/MediaGridCollectionView.swift`
- Method: `performZoomCrossFadeAnimation(from:to:)` in `MediaGridContainerView`

## Related Code

- `updateZoomLevel(to:animated:)` - Entry point that calls the animation
- `captureScrollPosition()` / `restoreScrollPosition(_:)` - Scroll position preservation (working)
- `snapshot()` extension on NSView - Creates bitmap snapshot (working)
