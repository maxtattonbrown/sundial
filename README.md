# Sundial

> A macOS menu-bar app that makes your laptop screen usable outdoors — and only burns the battery to do it when you actually need it.

<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue"> <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange"> <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-green">

## What it does

You take your MacBook Pro outside. The screen vanishes in direct sun because macOS caps SDR brightness around 600 nits — fine for cafés, invisible in noon sun. Meanwhile the panel can actually hit ~1000 nits sustained and ~1600 peak — that headroom is reserved for HDR content.

Sundial unlocks that headroom *only when you need it*.

- **Reactive brightness boost.** When macOS's brightness slider is pinned at max and stays there, Sundial requests EDR headroom from the panel — which lifts the backlight ceiling for everything on screen, not just our overlay. When you walk into shade and brightness drops, Sundial disengages within ten seconds. No always-on cost.
- **Sun-aware** (v0.2). Knows where the sun is in your sky, how bright it actually is outside (W/m², via Open-Meteo), and when it's setting. Sundial *is* a sundial.
- **Today in the sun** panel — passively tracks how long the boost has been engaged, the average UV during boost time, and a fuzzy Vitamin D estimate. The menu bar icon develops a tan as the day's outdoor minutes add up.
- **Soft engage/disengage.** The boost eases on over 800ms and off over 1.2s — sun-coming-out-from-behind-a-cloud rather than a light switch.
- **Honest battery cost indicator.** Measures the real wattage delta on your specific machine via `ioreg AppleSmartBattery`, projects it as "≈ −N min / hr" so you can see what the boost actually costs.

There are paid apps (Vivid, BetterDisplay) that sell a permanent brightness boost. Sundial's bet is that **permanent boost is the wrong shape** — the auto-brightness in macOS is already doing the right thing, and the only honest job for an outdoor mode is to top it up reactively, then tell you a story about the time you spent in the sun.

## Install

You'll need [xcodegen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
git clone https://github.com/maxtattonbrown/sundial.git
cd sundial
xcodegen generate
open Sundial.xcodeproj
# ⌘R to run, or:
xcodebuild -project Sundial.xcodeproj -scheme Sundial -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/Sundial.app
```

Drag `Sundial.app` to `/Applications` if you want to keep it. The first launch may need a right-click → Open dance since the binary is ad-hoc signed.

To run the tests:

```sh
xcodebuild -project Sundial.xcodeproj -scheme Sundial test
```

## How to use

A small sun icon appears in your menu bar. Click it:

- **Toggle ON** — Sundial starts watching the OS brightness slider. The boost stays *dormant* (yellow dot) while indoor brightness is fine.
- Drag macOS's brightness slider all the way up → the boost engages within ~6 seconds (orange dot), screen visibly brightens past slider-max.
- Drag brightness back down → boost disengages within ~10 seconds.
- The slider in the popover tunes how aggressive the boost is (1.5× subtle → 4.0× aggressive, default 2.5×).
- The battery indicator shows the real measured cost when engaged.

That's the whole UI.

## How it works

### The EDR trick

macOS exposes **Extended Dynamic Range** to apps that opt in via `CAMetalLayer.wantsExtendedDynamicRangeContent`. When a layer presents pixels with values > 1.0 in an extended-linear colour space, the mini-LED panel responds by lifting its overall backlight ceiling — which brightens *every* on-screen pixel, not just the requesting layer.

Sundial creates one transparent fullscreen `NSWindow` per `NSScreen` at `.screenSaver` level. Each hosts a `CAMetalLayer` with:

- `pixelFormat = .rgba16Float`
- `wantsExtendedDynamicRangeContent = true`
- `colorspace = extendedLinearDisplayP3`

It clears each frame to `(2.5, 2.5, 2.5, 0.05)` — premultiplied RGB above 1.0 (the EDR signal) at 5% alpha (so the overlay's visible contribution is tiny). The panel sees the EDR request and lifts the ceiling; you see brighter content.

A 1Hz redraw timer keeps the headroom granted — some macOS versions revoke it if the layer goes idle.

### The reactive trigger

[`BoostTrigger`](Sundial/State/BoostTrigger.swift) is a pure hysteresis state machine. [`BrightnessPoller`](Sundial/Utilities/BrightnessPoller.swift) calls `DisplayServicesGetBrightness` (resolved via `dlopen` so we don't ship private headers) every 3 seconds and feeds the trigger:

- **dormant → engaged** at brightness ≥ 0.99 for 2 consecutive reads (≈ 6 seconds)
- **engaged → dormant** at brightness ≤ 0.95 sustained for 10 seconds

The asymmetric thresholds prevent oscillation: once the boost is on, brief brightness dips don't toggle it off; once off, brief spikes don't toggle it on. The dead zone (0.95–0.99) keeps the boost sticky until the sun is actually gone.

### The battery cost measurement

Sundial samples the laptop's instantaneous discharge wattage from `ioreg AppleSmartBattery` (Amperage × Voltage) **before** engaging and **8 seconds after**. The delta is the boost's real cost on your specific machine. That's then projected as "minutes of total battery lost per hour of boost use" assuming a ~70Wh battery.

No modelling, no manufacturer-quoted figures — just measurement.

### Sun position

Sundial computes the sun's azimuth and elevation locally via [Schlyter's algorithm](https://stjarnhimlen.se/comp/ppcomp.html) — ~100 lines of pure math, accurate to 0.01°, no network, no API key. It needs your latitude/longitude (from `CLLocationManager`, ~3km accuracy is plenty). The popover shows the sun's height and bearing in real time.

### Weather and sunset (Open-Meteo)

For irradiance (W/m²), UV index, cloud cover, and accurate sunrise/sunset times, Sundial fetches from [Open-Meteo](https://open-meteo.com) — a free, no-account, no-API-key weather service. Refresh interval is 15 minutes; the data is cached between fetches. If you're offline, sun position keeps working (it's offline math); irradiance and sunset gracefully fall back to "unknown."

### The fuzzy Vitamin D estimate

The "Today in the sun" panel includes a Vitamin D percentage. This is **not medical** — it's a fuzzy heuristic: `UV_index × minutes_boosted ≈ percentage of daily target`, capped at 100%, zeroed below UV 1. The reference point: 20 minutes at UV 5 ≈ 100%. It's a story your laptop tells you about your day in the sun, not a clinical reading.

## Permissions

| Permission | Why | What happens if denied |
|---|---|---|
| **Location** (v0.2+) | Compute the sun's position in your sky and fetch local weather (Open-Meteo) | Sundial keeps working — the boost trigger doesn't depend on it. The "Today in the sun" panel hides and prompts you to grant location. |
| **App Sandbox** | Disabled — sandboxed processes can't `dlopen` the private `DisplayServices.framework` we need for brightness polling | Sundial doesn't ship via the App Store; this is a local-distribution tool. |

## Limitations

- **Mini-LED panels only.** The EDR brightness boost works on MacBook Pro M1 Pro/Max and later, and Pro Display XDR. It will technically run on Air models / older MBPs but won't visibly boost brightness because the panel can't.
- **Multi-display behaviour is naïve.** Sundial puts an EDR layer on every connected screen when engaged. Per-display tuning is out of scope for v0.1.
- **Keyboard-backlight-off feature was removed in v0.2.3.** The `NSEvent.systemDefined` route was unreliable on macOS 14+ for menu-bar (`LSUIElement`) apps regardless of Accessibility status. The feature may return in v0.3+ via IOKit `AppleKeyboardBacklight` once that's prototyped against real hardware.
- **Battery cost is qualitative.** The 70Wh constant is a rough M1/M2/M3 14" approximation. The displayed delta is real (measured discharge wattage), the projection to "minutes lost" is an estimate.
- **No app icon yet.** Menu bar uses the SF Symbol `sun.max.fill`. A real icon would be nice.

## Architecture

```
Sundial/
├── SundialApp.swift               # @main, NSApplicationDelegateAdaptor wiring
├── State/
│   ├── SundialManager.swift       # @Observable, owns side effects + isOn + persistence
│   ├── BoostTrigger.swift         # Pure hysteresis state machine (testable)
│   └── DailySunLog.swift          # Today's outdoor stats (UserDefaults, midnight rollover)
├── UI/
│   ├── PopoverPanel.swift         # Custom NSPanel + StatusBarController + tan-tint icon
│   └── SundialView.swift          # SwiftUI popover content
├── Features/
│   ├── EDRBoost.swift             # Per-screen EDR Metal layer + eased engage/disengage
│   └── BatteryCost.swift          # ioreg AppleSmartBattery sampling
└── Utilities/
    ├── BrightnessPoller.swift     # dlopen DisplayServicesGetBrightness
    ├── SunPosition.swift          # Schlyter's algorithm — pure math, offline
    └── SolarContext.swift         # CLLocationManager + Open-Meteo weather
Tests/
├── BoostTriggerTests.swift        # 11 tests — hysteresis state machine
├── SunPositionTests.swift         # 7 tests — sun azimuth/elevation accuracy
└── DailySunLogTests.swift         # 11 tests — Vitamin D math, time-weighted averages
                                   # Total: 29 tests, suite runs in ~40ms
```

Project file is regenerated from [`project.yml`](project.yml) via xcodegen — never edit `Sundial.xcodeproj` directly.

## Contributing

Bug reports and small PRs welcome. Bigger architectural changes — open an issue first.

If you build on the EDR trick: please document any panel-specific gotchas you discover. The mechanism is undocumented and macOS-version-sensitive, and the more people accumulate notes about what fails on what hardware, the more robust this stuff gets.

## License

MIT. See [LICENSE](LICENSE).

## Credits

Inspired by [Vivid](https://www.getvivid.app) and [BetterDisplay](https://github.com/waydabber/BetterDisplay) — Sundial is what happens when you ask "what if the boost was reactive instead of permanent?"

Built with [Claude Code](https://claude.com/claude-code) by [Max Tatton-Brown](https://maxtb.com).
