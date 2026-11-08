# Core

Every shared type in PrivacyPods. Nothing in here imports CoreMotion, ScreenCaptureKit,
IOBluetooth or Carbon; those stay inside the module that owns them.

The app is a single Swift module. "Module" below means a directory with an owner, not a
separate compilation unit, so everything in Core is visible everywhere without an import.
The discipline is social: if a type is needed by two directories, it belongs in Core; if it is
needed by one, it stays there.

## Ownership map

| Directory | Owns | Implements from Core |
| --- | --- | --- |
| `Core` | Shared value types and protocols. Frozen; propose changes, do not edit in place. | none |
| `HeadTracking` | `CMHeadphoneMotionManager`, quaternion to `HeadPose`, the sample-gap watchdog | `HeadTrackingProviding` |
| `Gaze` | Anchor table, nearest-anchor classifier, grace window, `NSEvent` monitors, Carbon re-anchor hotkey | `GazeClassifying`, `InputActivityProviding` |
| `Overlay` | One window per display, `SCStream` capture, `CIGaussianBlur`, the dark scrim over it | `OverlayControlling` |
| `Presence` | Gait detection, Bluetooth proximity, away evidence rules, screen lock | `PresenceProviding`, `ScreenLocking` |
| `App` | Entry point, engine wiring, menu bar, settings window, Status window, settings store | `PermissionAuditing` |

Modules never reference each other. `App` builds every provider, subscribes to every stream,
and pushes the results into whoever needs them. If you find yourself wanting another module's
type, you want a Core type instead, or you want `App` to do the wiring.

## Observation style

Two rules, and they do not overlap:

- **Signals use `AsyncStream`.** Anything that changes because the world changed (head samples,
  wear state, gaze, presence, input, lock state) is published as `var events: AsyncStream<T>`.
  Every such stream is **single-consumer**: the provider builds it once at init and `App` is the
  only reader. Do not hand the stream to two `for await` loops; they will split the events
  between them. If a second consumer is ever needed, `App` fans out.
- **UI state uses `@Observable`.** `App`'s settings store, permission auditor and menu-bar view
  model are `@MainActor @Observable` classes that SwiftUI reads directly. They mirror stream
  values into properties; they are not a second event channel.

Every stream emits on change only. None of them replay the current value, so read the paired
`var state` / `var wearState` / `var isLocked` property for the value at subscribe time.

All provider protocols are `@MainActor` and class-bound. The app coordinates on the main actor;
where an implementation needs a background queue (CoreMotion's `OperationQueue`, `SCStream`'s
sample callbacks, `system_profiler`), it hops back to the main actor before emitting.

## Value types

### Geometry.swift

- **`Degrees`**: an angle, `Double` inside, `Codable` as a bare number, literal-expressible
  (`let cone: Degrees = 25`). Build from CoreMotion with `Degrees(radians:)`; the whole point
  of the type is that a radian can never be passed where a degree is expected. `.normalized`
  wraps into `(-180, 180]`; `.magnitude` is the absolute value.
- **`HeadPose`**: `yaw` (positive = user turned to their left) and `pitch` (positive = chin up).
  Roll is not modelled. Absolute values are meaningless: the reference frame is established
  when the motion stream starts and drifts over minutes, so only
  `pose.offset(from: anchor.pose)` means anything. That call normalises both axes for you.
- **`AcceptanceCone`**: `yawHalfAngle` (default 25) and `pitchHalfAngle` (default 20).
  `contains(_ offset:)` answers "inside this display's cone". `normalizedDistance(_ offset:)`
  returns `0` at dead centre and `1` on the boundary; **compare candidate displays on this, not
  on raw degrees**, so a wide cone and a tall one are judged on the same scale.
- **`Vector3`**: a three-axis reading, in whatever units the sensor gave it.
- **`MotionSample`**: `pose`, `userAcceleration` (gravity-removed, in g, device frame), and a
  `timestamp`. The only thing `HeadTracking` emits per update.

### Displays.swift

- **`DisplayID`**: wraps `CGDirectDisplayID`. The key for anchors and overlay windows.
- **`DisplayInfo`**: `id`, `name`, `frame` (global AppKit coordinates).
  `DisplayInfo.current()` snapshots the attached displays and `DisplayInfo.containing(_ point:)`
  finds the one under a point such as `NSEvent.mouseLocation`. Both are `@MainActor`.
  **Use these rather than re-deriving the ID**: the `NSScreenNumber` device-description lookup
  is the only supported `NSScreen` to `CGDirectDisplayID` bridge and it is easy to get wrong.
  Both are snapshots, valid until the next `didChangeScreenParametersNotification`.
- **`DisplayAnchor`**: `display`, `pose`, `capturedAt`, `source`. `Source` is `.sustainedInput`
  or `.hotkey`; a hotkey anchor overrides a sustained-input one unconditionally.

### States.swift

- **`WearState`**: `.worn` or `.unknown(Reason)`, where `Reason` is `.noHeadphonesConnected`,
  `.sampleGap`, `.motionUnavailable` or `.permissionDenied`. **There is deliberately no
  `notWorn`.** The sensors cannot tell "in the case" from "on the desk" from "connected but
  silent", and treating any of those as "the user left" is what makes an app like this
  unusable. `.unknown` never justifies an away state or a lock.
- **`GazeState`**: `.looking(DisplayID)`, `.away`, `.unknown`. `.unknown` is a sensor gap and
  is never a substitute for `.away`. `.display` unwraps the focused display.
- **`PresenceState`**: `.present`, `.unknown`, `.away(since: Date)`.
- **`AwayResponse`**: `.idle < .blur < .lock`. `Comparable`, so a driver can compare against
  what it has already done and act only on escalation.
- **`CaptureAvailability`**: `.available`, or `.unavailable(.screenRecordingDenied)` /
  `.unavailable(.captureFailed)`. Whether the overlay is blurring a live picture of a display or
  covering it blind; `notice` is the one line printed on the cover, and `nil` while it can blur.
  Either way the display stays covered: the failure changes what the user is told, never
  whether the screen is hidden.

### Settings.swift

- **`BlurMode`**: `.off`, `.whenLookingAway` (default), `.unfocusedDisplays`. Carries a `title`
  for the picker so the menu bar and the settings window cannot disagree.
- **`FailMode`**: `.open` (default, stay readable during a sensor gap) or `.closed` (blur).
  Governs blur only; a gap never produces an away state or a lock in either mode.
- **`AwayPolicy`**: `.doNothing`, `.blurThenLock(blurAfter:lockAfter:)` (default 5 s / 30 s),
  `.lockImmediately`. `response(awayFor:)` maps elapsed seconds to an `AwayResponse`; it is pure
  and already tested, so do not reimplement the thresholds.
- **`Hotkey`**: `keyCode` plus `Modifiers`. `modifiers.carbonFlags` is the mask
  `RegisterEventHotKey` wants and `modifiers.symbols` is the `⌃⌥⌘` string for menus.
  `.reanchorDefault` is ⌃⌥⌘R.
- **`AppSettings`**: `isEnabled`, `blurMode`, `awayPolicy`, `failMode`, `acceptanceCone`,
  `awayGrace` (0.7 s), `reanchorHotkey`, `launchAtLogin`, `blurRadius` (70 pt). Every field has
  a default and decoding is field-by-field, so adding a setting does not wipe a user's stored
  preferences. Persist the whole struct as JSON under `AppSettings.defaultsKey`. A field that
  is present but malformed still throws; the settings store treats that as "use defaults".
- **`BlurMode.displaysToBlur(gaze:allDisplays:failMode:)`**: the single source of truth for
  what is blurred right now. It handles the mode matrix and the fail-mode gap rule. The caller
  still owns the gates above it: a disabled app, a locked screen, and an away escalation all
  bypass this function.

### Permissions.swift

- **`Permission`**: `.motion`, `.screenRecording`, `.inputMonitoring`, `.bluetooth`, each with a `title`, a
  `rationale` for the Status window, and a `settingsURL` pointing at the right
  System Settings pane.
- **`PermissionStatus`**: `.granted`, `.denied`, `.notDetermined`, `.unavailable`.

### TimeSource.swift

- **`TimeSource`** / **`SystemTimeSource`**: injected "now". Reach for it only where a type
  owns a timer it cannot hand to its caller. **Pure state machines should take `now: Date` as a
  parameter instead**, which is how the tested logic stays free of clocks.
  `Tests/PrivacyPodsTests/Support/ManualTimeSource.swift` is the shared steppable fake; treat
  that file as frozen so parallel test authors do not collide.

### Log.swift

- **`Log`**: one `os.Logger` per module (`.app`, `.headTracking`, `.gaze`, `.overlay`,
  `.presence`). Use these rather than making your own, so
  `log stream --subsystem dev.wesley.privacypods` shows the whole app.

## Protocols

All are `@MainActor` and `AnyObject`.

| Protocol | Owner | Surface |
| --- | --- | --- |
| `HeadTrackingProviding` | HeadTracking | `events: AsyncStream<HeadTrackingEvent>`, `wearState`, `start()`, `stop()` |
| `InputActivityProviding` | Gaze | `events: AsyncStream<InputActivity>`, `start()`, `stop()` |
| `GazeClassifying` | Gaze | `state`, `events: AsyncStream<GazeState>`, `anchors`, `ingest(_:)`, `anchor(_:source:)`, `retainOnly(_:)`, `update(cone:awayGrace:)` |
| `OverlayControlling` | Overlay | `captureAvailability`, `captureEvents: AsyncStream<CaptureAvailability>`, `setBlurred(_:radius:notices:)`, `teardown()` |
| `PresenceProviding` | Presence | `state`, `events: AsyncStream<PresenceState>`, `ingest(_:)` x3, `start()`, `stop()` |
| `ScreenLocking` | Presence | `isLocked`, `events: AsyncStream<Bool>`, `lock() -> Bool` |
| `PermissionAuditing` | App | `status(of:)`, `request(_:)`, `refresh()` |

Notes the signatures do not carry:

- `HeadTrackingProviding` implementations must run their own gap watchdog and emit
  `.wearState(.unknown(.sampleGap))` unprompted. Silence is the only signal AirPods give when
  they leave a head, so nobody can ask for it.
- `GazeClassifying.anchor(_:source:)` takes no pose: the classifier already holds the latest
  one. It applies the grace window on the way out of `.looking` and switches back to a display
  immediately, so a glance away does not flicker the overlay.
- `GazeClassifying.update(cone:awayGrace:)` re-judges the pose it is already holding, so
  widening a cone in the settings window unblurs at once rather than at the next sample. `App`
  calls it from its settings observer.
- **Permissions are reported in one place.** `PermissionAuditing` is the only permission
  surface; no provider publishes its own status. It reads Motion through
  `HeadphoneMotionTracker.authorizationStatus` and Screen Recording through
  `ScreenRecordingPermission`, so the modules that own those APIs stay the only callers of them.
  *Requesting* Motion is the exception worth knowing about: CoreMotion has no request call, so
  `PermissionAuditing.request(.motion)` runs `HeadphoneMotionTracker.requestAuthorization()`,
  which opens the motion stream for up to two seconds. That is a sensor start, so the UI asks
  through `AppCoordinator.request(_:)` rather than the auditor directly, and the probe never
  runs behind the app's enabled/unlocked gate. The other two permissions have no side effect.
- `ScreenLocking.lock()` returns whether anything took effect. `SACLockScreenImmediate` can fail
  and the display-sleep fallback only locks when the password delay is immediate, so a caller
  that ignores the result can believe it locked a Mac that is still showing the user's screen.
- `OverlayControlling.setBlurred(_:radius:notices:)` is idempotent and absolute, not a delta. Pass the
  full set every time; anything blurred and not in the set fades out.
- `PermissionAuditing.refresh()` exists because TCC sends no change notifications. Call it when
  the Status window appears and when the app returns to the foreground.

## Ground truth from the spike

`spike/README.md` has the measurements behind three constraints that will otherwise cost a day:

1. **The app must be launched through LaunchServices** (`open -n PrivacyPods.app`), never as a
   binary from a terminal. TCC checks the *responsible* process, so a terminal-launched build is
   SIGABRT'd at `startDeviceMotionUpdates` with no Swift error. Exit code 134.
2. **`isDeviceMotionAvailable` is not a permission check.** It returns `true` while
   unauthorised. It means "headphones with a gyro are connected", which maps to
   `WearState.Reason.noHeadphonesConnected` when false, nothing more.
3. **`IOBluetoothDevice.rawRSSI()` returns 0 on every connected device** on macOS 26. It is a "no
   data" sentinel rather than a reading, with no error raised. The working source is
   `system_profiler SPBluetoothDataType -json`, which is a ~1 s subprocess, so proximity is a
   low-rate coarse signal and can never be responsive. Presence must work without it.

Also from the spike: the first sample of each motion run is garbage (roll ~90 degrees,
acceleration ~1 g) and settles within two samples. Discard it.
