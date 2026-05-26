# Sundial

Menu-bar app for Mr.Maximilian's MacBook Pro that makes it usable outdoors. Two features (post v0.2.3):

1. **Reactive EDR brightness boost** — engages when the OS brightness slider crosses 0.95 sustained and disengages with hysteresis (≤0.85 for 10s). Threshold tuned to macOS auto-brightness reality: the slider caps at ~0.98 in direct sun, never literally 1.0.
2. **Battery cost indicator** — reads `ioreg AppleSmartBattery` Amperage × Voltage before/after engaging boost. Displays real measured delta as "≈ −X min/hr battery". Goes red below 30%.

Plus solar awareness (sun position, sunset countdown, "Today in the Sun" log with fuzzy Vitamin D %) and a tan-tint menu bar icon that accumulates colour as the day's boost minutes add up.

**Removed in v0.2.3:** Keyboard-backlight-off feature. The `NSEvent.systemDefined` route was unreliable on macOS 14+ for `LSUIElement` apps and the Accessibility permission UX was confusing. Removed cleanly rather than left half-working. May return in v0.3+ via the IOKit `AppleKeyboardBacklight` route once that's prototyped against real hardware.

True Tone is intentionally **not** included — under blue daylight it shifts cooler, which actually helps outdoor readability. See plan at `~/.claude/plans/could-we-make-it-swift-mountain.md`.

## Current state (2026-05-26)

- **`main` is the shipping line**: v0.5.1 + location fix (`db0c3f1`). UI is the **UnifiedBar** — a continuous brightness fill (left) crossing into 4 boost-intensity chunks (right). Public on GitHub, listed on the profile README.
- **Dynamic boost**: `computeEffectiveBoost` ramps 1.5×→3.0× as irradiance climbs 200→800 W/m² (UK-realistic ceiling). Gated on solar availability — see open items.
- **Parked experiment**: branch `the-sun` (tag `v0.6.0-alpha`) replaced the bar with a single animated sun (UV-driven core + boost-driven halo). Abandoned 2026-05-26 — "too literal." Kept on GitHub as the record; `main` is canonical.

### Open items / next session
1. **Verify location on real hardware** (the one thing left). The "only ever boosts to the same level" bug was the boost silently flooring at 1.5× because solar data was never available — root cause was the wrong Info.plist key (`NSLocationUsageDescription` instead of the required `NSLocationWhenInUseUsageDescription`), fixed in `db0c3f1`. Key is confirmed present in the built plist, but a *grant* is unverified: ad-hoc signing (`TeamIdentifier=not set`) wipes the TCC grant on every rebuild, and background launches can't click the prompt. Launch from `/Applications`, click Allow, confirm the 4 chunks climb with the sun (≈2 mid-morning → ≈4 at noon).
2. **If location won't grant** even with Location Services on → decouple the boost from location: usable default boost standalone, weather/UV as a *bonus* refinement, not a gate. Today a permission failure silently cripples the headline feature. See `lesson_silent_dependency_floor` in memory.
3. **Deferred review finding**: per-zone fast/slow dwell tracking to stop oscillation across the 0.60 fast-disengage boundary (`BoostTrigger`).

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
- `Sundial/State/BoostTrigger.swift` — pure hysteresis state machine, testable
- `Sundial/State/DailySunLog.swift` — today's boost minutes + Vitamin D math, UserDefaults-persisted
- `Sundial/UI/PopoverPanel.swift` — custom NSPanel + StatusBarController + tan-tint icon
- `Sundial/UI/SundialView.swift` — SwiftUI popover content
- `Sundial/Features/EDRBoost.swift` — Metal EDR layer per NSScreen + eased engage/disengage transitions
- `Sundial/Features/BatteryCost.swift` — ioreg AppleSmartBattery sampling
- `Sundial/Utilities/BrightnessPoller.swift` — dlopen DisplayServicesGetBrightness, polls every 3s
- `Sundial/Utilities/SunPosition.swift` — Schlyter's algorithm, offline sun position math
- `Sundial/Utilities/SolarContext.swift` — CLLocationManager + Open-Meteo weather/sunset

## Permissions

- **Location** — used to compute the sun's position and fetch local weather from Open-Meteo. Prompted on first toggle-on; Sundial keeps boosting without it (the "Today in the Sun" panel just hides).
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

### macOS auto-brightness slider caps below 1.0

In direct sun on Apple Silicon, `DisplayServicesGetBrightness` returns approximately 0.98, NOT 1.0. macOS auto-brightness reserves headroom (~2%) for True Tone / Night Shift / HDR rendering on top of the user-visible brightness target. Undocumented but consistent across machines.

**Implication for thresholds:** anything looking for "user wants max brightness" must use a threshold of ~0.95, not 0.99 or 1.0. Sundial v0.2.0-v0.2.1 had a 0.99 engage threshold and never fired in real outdoor conditions. Pinned by `test_engagesWhenAutoBrightnessCapsBelow1` in `Tests/BoostTriggerTests.swift`.

Future investigation: read the ambient light sensor directly via IOKit (the Apple Silicon successor to `AppleLMUController`) to bypass the slider proxy entirely. Planned as v0.3 work.

### Test data leaks into production UserDefaults

Default Xcode test targets run **in the host app's process**, so `UserDefaults.standard` in a test points to `com.maxtb.sundial.plist` — the same plist the real app reads. Tests that write to `UserDefaults.standard` will pollute the user's actual app state.

`DailySunLog` and any future persistence layer must accept an injected `UserDefaults` instance and tests must use `UserDefaults(suiteName: "Sundial.tests.\(UUID())")` with cleanup in `tearDown`. Pinned by `test_doesNotLeakIntoStandardDefaults`.
