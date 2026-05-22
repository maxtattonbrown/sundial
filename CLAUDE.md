# Sundial

Menu-bar app for Mr.Maximilian's MacBook Pro that makes it usable outdoors. Three features only:

1. **Reactive EDR brightness boost** — engages only when the OS brightness slider is already pinned at max and stays high (≥0.99 sustained). Disengages with hysteresis (≤0.95 for 10s) so brightness flutter doesn't oscillate the boost.
2. **Keyboard backlight off** — pushed to zero via simulated F5 illumination-down events when Sundial is on. Restored via F6 on disable. Requires Accessibility permission.
3. **Battery cost indicator** — reads `ioreg AppleSmartBattery` Amperage × Voltage before/after engaging boost. Displays real measured delta as "≈ −X min/hr battery". Goes red below 30%.

True Tone is intentionally **not** included — under blue daylight it shifts cooler, which actually helps outdoor readability. See plan at `~/.claude/plans/could-we-make-it-swift-mountain.md`.

## Build

```
brew install xcodegen   # one-time
xcodegen generate
open Sundial.xcodeproj
# Cmd+R to run
```

The `.xcodeproj` is gitignored — always regenerated from `project.yml`.

## Architecture

- `Sundial/SundialApp.swift` — @main, NSApplicationDelegateAdaptor wiring
- `Sundial/State/SundialManager.swift` — `@Observable` master state, owns the engaged/dormant state machine
- `Sundial/UI/PopoverPanel.swift` — custom NSPanel + StatusBarController (forked from `~/Projects/desk-controller/`)
- `Sundial/UI/SundialView.swift` — SwiftUI popover content
- `Sundial/Features/EDRBoost.swift` — Metal EDR layer per NSScreen; renders fullscreen low-alpha extended-range white to lift the panel ceiling
- `Sundial/Features/KeyboardBacklight.swift` — NSEvent.systemDefined illumination keys (F5/F6) via accessibility
- `Sundial/Features/BatteryCost.swift` — ioreg AppleSmartBattery sampling
- `Sundial/Utilities/BrightnessPoller.swift` — dlopen DisplayServicesGetBrightness, polls every 3s

## Permissions

- **Accessibility** — needed only for the keyboard-backlight feature (sends F5/F6 illumination key events). Prompted on first toggle-on; Sundial proceeds without it (keyboard feature silently no-ops).
- **No app sandbox** — needed because `dlopen` of `/System/Library/PrivateFrameworks/DisplayServices.framework` is blocked in a sandboxed process. Distributed locally only.

## Gotchas

### EDR clearColor is already-premultiplied, not unpremultiplied

`CAMetalLayer` with `pixelFormat = .rgba16Float` and `extendedLinearDisplayP3` colorspace uses **premultiplied alpha** — the values you write to `MTLRenderPassDescriptor.colorAttachments[0].clearColor` *are the final framebuffer pixel values*, already premultiplied. To request EDR headroom from the panel, the RGB components must exceed 1.0 *as written*.

The natural-looking mistake is to think you need to premultiply yourself:

```swift
// WRONG — produces an SDR pixel, no EDR request
let alpha: Float = 0.04
let edrValue: Float = 4.0
clearColor = MTLClearColor(red: 4.0 * 0.04, ...)   // = 0.16, below SDR white
```

```swift
// RIGHT — RGB > 1.0 directly, alpha controls visible contribution
let edrValue: Float = 2.5
let alpha: Float = 0.05
clearColor = MTLClearColor(red: 2.5, ..., alpha: 0.05)
```

The visible luminance contribution at the composite step is roughly `edrValue * alpha` (0.125 here), so a high `edrValue` with low `alpha` lifts the panel ceiling without the overlay visibly washing the screen out. Symptom of the bug: app says "Engaged" in the popover but the screen brightness doesn't change at all.

### `metalLayer.drawableSize` must be in pixels on Retina

`metalLayer.frame = bounds` is in points (½ resolution on Retina). Set `drawableSize` to `bounds * backingScaleFactor` to render at native resolution. Some EDR pipelines won't grant headroom for a layer mismatched to its display's native res.

### Keyboard backlight injection requires Accessibility

`NSEvent.systemDefined` subtype-8 events (the F5/F6 illumination keys) need Accessibility permission to inject. Sundial checks `AXIsProcessTrusted()` and silently no-ops if denied — Mr.Maximilian can grant later via System Settings → Privacy & Security → Accessibility. On some macOS versions this path may be locked down even with Accessibility granted; if keyboard backlight doesn't drop when Sundial engages, this is the suspect.
