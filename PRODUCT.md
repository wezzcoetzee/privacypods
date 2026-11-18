# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

The real platform is **macOS**: a native menu bar app (SwiftUI + AppKit, macOS 26+, no dock icon). Impeccable has no macOS value, so `ios` is recorded to get Apple-native guidance (HIG, SF Symbols, semantic system colors, San Francisco). The macOS HIG overrides every iOS-only rule: no 44pt touch targets, tab bars, safe areas, large titles or edge-swipe back; menus, menu bar extras, windows, pointer and keyboard are the interaction model. The only web surface is the store-image renderer in `scripts/appstore/slides.html`, which produces PNGs, not a shipped page.

## Users

Mac users who already wear AirPods Pro (or other gyro-equipped AirPods/Beats) while working in public or shared spaces: cafes, trains, coworking spaces, open offices. Their job is to keep working without someone reading their screen over their shoulder, and without leaving an unlocked Mac behind when they get up.

Secondary: people with more than one display, who benefit from only the display they are looking at staying readable.

## Product Purpose

PrivacyPods uses the head tracking the AirPods already provide to blur displays when the user looks away (all displays, or the ones not being looked at) and to lock the Mac when the user walks off. Success means it protects the screen in the moments that matter and never acts on guesses: a missing signal is reported as missing, never treated as the user leaving.

## Positioning

It needs no camera, no extra hardware and no setup ritual: the sensor is the headphones the user is already wearing. Presence is judged from evidence (walking gait, disconnect plus no input, Bluetooth proximity as corroboration only), and the app is openly honest about what it cannot see.

## Operating Context

- Lives in the menu bar. The icon state is the primary status surface; dimmed means the user chose it (paused, or blur and lock off).
- Windows: Status (permissions, lock test, setup steps; opens itself on first launch), Settings, and the menu.
- Four TCC permissions: Motion (required, no fallback), Screen Recording, Input Monitoring, Bluetooth. Each degrades differently and the UI says exactly how.
- Anchoring, not calibration: sustained typing or pointer input re-anchors gaze to the display under the cursor. A re-anchor hotkey covers long reading sessions.
- Every lock is verified. A lock that does not take is surfaced in the menu and Status window, and displays stay blurred.
- iPhone automatic device switching silently takes the head-motion stream; the fix lives on the phone, and the docs say so.

## Capabilities and Constraints

- Supported: AirPods Pro (all), AirPods 3rd gen and later, AirPods Max, Beats Fit Pro. AirPods 1st/2nd gen and most Beats have no gyro.
- Not sandboxed, not on the Mac App Store: it uses a private lock-screen entry point and four TCC permissions.
- Distribution: free, currently an ad-hoc signed DMG on GitHub Releases. Direction: notarized and still free, with a proper download page. Monetization is not planned.
- Screen capture runs about 4 fps and only while a display is blurred.
- Known limits: yaw drift between input bursts, coarse Bluetooth proximity, vertically stacked or similarly angled displays can overlap, no camera fallback yet.
- Planned, not built: webcam face-pose fallback, Apple Watch proximity, per-app exclusions, per-display blur strength, meeting mode.
- Terminology: "anchor", "away", "blind" (display covered without a capture to blur), "Status window", "Lock Now to Test".

## Brand Commitments

- Name: PrivacyPods. Identity built from SF Symbols (the eye family in the menu bar; the app icon is generated from SF Symbols by `scripts/icon/render.swift`).
- Voice: honest first. State limits plainly, never claim protection the app cannot give, call missing data missing. Warmth is welcome, especially on marketing surfaces, but never at the cost of accuracy.
- Copy avoids em dashes.

## Evidence on Hand

- Store-size images (2880×1800) in `docs/appstore/`: real renders of the app's windows and menu; the documents behind the blur are made up.
- `scripts/snapshots.sh` renders every window, menu, icon state and overlay against fake sensors.
- The app has not yet been exercised on real AirPods hardware. No users, testimonials, reviews, press or usage numbers exist. Do not fabricate any of them, and do not claim hardware-verified behavior until it is.
- No license file is checked in.

## Product Principles

1. Silence is not absence. Missing data never locks and only blurs when the user asked for that.
2. Say what is wrong and the one thing to do next. Every degraded state is visible and named.
3. Verify before trusting. A lock is tested before it is relied on, and a failed lock is never hidden.
4. Stay out of the way. Menu bar only, no dock icon, no setup beyond permissions; the headphones are the sensor.
5. Dimmed means chosen. Visual state distinguishes "you turned this off" from "something needs fixing".
