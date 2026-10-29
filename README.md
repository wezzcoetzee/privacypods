# PrivacyPods

Your AirPods already know where your head is pointing. PrivacyPods uses that to blur your
screens when you look away, and to lock the Mac when you walk off.

It lives in the menu bar, has no dock icon, and does nothing at all unless it can prove your
AirPods are on your head.

> Status: complete and wired, but only ever exercised on a Mac without AirPods paired. The
> head-tracking, blur and lock paths have not been watched on real hardware yet.
> `Sources/PrivacyPods/Core/README.md` is the contract, `docs/ARCHITECTURE.md` is the map.

## What it does

- Reads head orientation from your AirPods and works out which display you are looking at.
- Blurs the displays you are not looking at, or every display when you look away. Your choice.
- Notices when you stand up and leave, and locks the screen after a delay you set. If the lock
  does not take, the menu bar says so and the displays stay blurred.
- Stops as soon as the AirPods come off. A missing signal is treated as a missing signal, never
  as an absent user: it can blur, if you ask it to, but it never decides you left and it never
  locks.

## Install

Build the DMG with `./scripts/build-dmg.sh` (see [Building](#building)), open it, and drag the
app into Applications.

The build is ad-hoc signed, not notarised, so Gatekeeper blocks the first launch. Right-click the
app, choose Open, and confirm once. Then open Calibration from the menu bar icon and grant the
three permissions.

The menu bar icon holds everything: a live status line, Enabled, Blur Mode, Re-anchor Now,
Calibration, Settings, Launch at Login and Quit.

## Supported headphones

Anything with a gyroscope that reports through `CMHeadphoneMotionManager`:

- AirPods Pro (all generations)
- AirPods (3rd generation and later)
- AirPods Max
- Beats Fit Pro

AirPods (1st and 2nd generation) and most Beats have no gyro and will not work.

## The iPhone caveat

Automatic device switching is the one thing that will quietly break this. When your iPhone
decides it wants the AirPods, the head-motion stream goes with it, and PrivacyPods sees exactly
what it sees when you take the AirPods out: silence. It will fall back to its unknown state and
stop acting.

There is no API to stop this from the Mac side. Manage it on the phone:
Settings > Bluetooth > your AirPods > Connect to This iPhone > When Last Connected to This iPhone.

## Permissions

| Permission | Why | Without it |
| --- | --- | --- |
| Motion | Read AirPods head orientation | Nothing works. There is no fallback. |
| Screen Recording | Capture each display so the overlay has something to blur | No blurred capture. The display is still covered, but blind: dark glass with one line saying why, never the live screen. Calibration shows it too |
| Input Monitoring | Notice typing and pointer movement, so anchors set themselves | Only pointer events get through: anchoring leans on the pointer and the hotkey, and typing no longer resets the away timers. Granting it mid-session takes effect within about five seconds, with no relaunch |

All three are requested from the Calibration window, which shows live status for each one and a
button through to the right System Settings pane. See `docs/PERMISSIONS.md` for the detail on
each one, including the Motion TCC trap.

Because of how TCC attributes permissions, PrivacyPods must be launched as an app bundle
(Finder, Spotlight, or `open -n PrivacyPods.app`). Running the binary directly from a terminal
makes the terminal the responsible process, and the Motion grant will not apply.

## How anchoring works

Head tracking is relative, not absolute. There is no "straight ahead" to measure against, and
the zero point drifts over minutes. Calibrating once would be wrong within the hour.

So PrivacyPods never calibrates. It anchors, continuously:

1. You type, or move the mouse, for long enough that it is clearly deliberate. Key auto-repeat
   and scroll momentum do not count; only a human at the keyboard moves the anchor.
2. PrivacyPods assumes you are looking at the display your cursor is on.
3. It records your current head angle as that display's anchor.

From then on, "which display are you looking at" is the nearest anchor within an acceptance cone
(25 degrees of yaw, 20 of pitch, both adjustable). Outside every cone means you are looking away.
Drift gets absorbed every time you touch the keyboard, so it never accumulates.

Leaving a display is damped by a grace window (700 ms) so a glance at a colleague does not
flicker the screen. Coming back is immediate.

If the anchor for a display is wrong, look at it and press ⌃⌥⌘R.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Blur mode | When looking away | Or unfocused displays, or off |
| Away policy | Blur after 5 s, lock after 30 s | Or lock immediately, or do nothing |
| Fail mode | Stay readable | What to do while head data is missing. Blur only; a sensor gap never locks |
| Acceptance cone | 25 degrees yaw, 20 pitch | Widen if the app loses you when you glance at a corner |
| Grace window | 700 ms | How long you must look away before it counts |
| Re-anchor hotkey | ⌃⌥⌘R | Anchors the display under the cursor. Click the field in Settings and press a new combination to change it |
| Blur radius | 70 pt | |
| Launch at login | Off | |
| Enabled | On | Turning it off stops every sensor, clears the overlay and cancels any away escalation, so nothing blurs and nothing locks. Locking the screen does the same, and both drop the anchors |

## Building

Requires Xcode 27 (Swift 6.4) on macOS 26 or later, and
[xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project PrivacyPods.xcodeproj -scheme PrivacyPods \
  -configuration Debug -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

`PrivacyPods.xcodeproj` is generated and not checked in. Edit `project.yml` instead.

For an installable build:

```sh
./scripts/build-dmg.sh   # writes dist/PrivacyPods-<version>.dmg
```

The DMG is ad-hoc signed. TCC grants survive rebuilds because the bundle id does not change.

The app icon is generated, not drawn by hand. `scripts/icon/render.swift` composes it from SF Symbols and
`scripts/icon/make-icns.sh` writes `Supporting/AppIcon.icns`, which is checked in.

Tests are Swift Testing and cover pure logic only:

```sh
xcodebuild -project PrivacyPods.xcodeproj -scheme PrivacyPods \
  -configuration Debug -destination 'platform=macOS' test \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

The app is not sandboxed and is not distributed through the App Store. It uses a private
lock-screen entry point and needs three TCC permissions, none of which survive the sandbox.

## Project layout

| Path | What lives there |
| --- | --- |
| `Sources/PrivacyPods/Core` | Shared types, settings, protocols. Its `README.md` is the contract every module codes against |
| `Sources/PrivacyPods/HeadTracking` | AirPods motion stream and the wear state machine |
| `Sources/PrivacyPods/Gaze` | Display anchors, deliberate-input detection, the gaze classifier |
| `Sources/PrivacyPods/Presence` | Gait, Bluetooth proximity, away policy and screen locking |
| `Sources/PrivacyPods/Overlay` | Screen capture and the blur overlay windows |
| `Sources/PrivacyPods/App` | Menu bar, Settings and Calibration UI, and the coordinator that wires it all together |
| `Tests/PrivacyPodsTests` | Swift Testing suites, mirroring the source folders |
| `docs/` | `ARCHITECTURE.md` and `PERMISSIONS.md` |
| `scripts/` | DMG packaging and icon generation |
| `spike/` | The throwaway probes that proved head motion and Bluetooth work before the app existed |

## Known limitations

- **Yaw drifts.** Anchoring hides it as long as you keep typing. If you read for twenty minutes
  without touching anything, the anchor will be stale when you come back. The hotkey fixes it.
- **Bluetooth proximity is coarse.** `IOBluetoothDevice.rawRSSI()` returns 0 on modern macOS, so
  the only working source is a `system_profiler` subprocess that takes about a second. Proximity
  is a slow corroborating signal, never a trigger on its own.
- **Two displays in a line are hard to tell apart.** Displays stacked vertically or angled
  similarly can fall inside each other's cones. Narrow the acceptance cone if this bites.
- **The AirPods have to be on.** There is no camera fallback yet.
- **Screen capture costs something.** Capture runs at about 4 fps and only while a display is
  actually blurred, but it is not free.

## Future enhancements

- **Webcam face-pose fallback** via Vision, for when the AirPods are out or handed to a phone.
  This is the one that removes the hard dependency on headphones.
- **Apple Watch proximity** as a second presence signal, more reliable than Bluetooth RSSI and
  already on the user's wrist.
- **Per-app exclusions**, so a media player or a presentation never gets blurred.
- Per-display blur strength, for the display with the sensitive thing on it.
- A "meeting mode" that blurs everything but the app you are sharing.
