# Permissions

PrivacyPods asks for four TCC permissions (`Permission` in
`Sources/PrivacyPods/Core/Permissions.swift`). Each is shown in the Status window with live status
and a button through to the right System Settings pane when the OS will not prompt in-process.
The ones PrivacyPods can ask for itself are also offered from the menu while unasked.

None of these survive App Sandbox, which is why the app is not sandboxed and is not distributed
through the App Store.

## Motion

**Why:** `CMHeadphoneMotionManager` is gated by `kTCCServiceMotion`. Without it PrivacyPods has
no head orientation at all, so this is the one permission with no fallback: everything else in
the app (gaze, presence, overlay) is downstream of it.

**Declared as:** `NSMotionUsageDescription` in `Supporting/Info.plist`.

**Requesting it:** the first call to `CMHeadphoneMotionManager.startDeviceMotionUpdates` triggers
the system prompt, so there is no authorization API to call: asking means running a short-lived
probe (`HeadphoneMotionTracker.requestAuthorization()`), which starts the stream only long enough
for TCC to answer and then stops it again. Starting a sensor belongs to the run gate, so the
Status window asks through `AppCoordinator.request(_:)`, which refuses while tracking is
already running: at which point the status is known anyway and the button is hidden. Once TCC has
answered, there is nothing left to prompt and the button opens the System Settings pane instead.
`HeadphoneMotionTracker.authorizationStatus` reports the current state without prompting, and is
the only reader of `CMHeadphoneMotionManager.authorizationStatus()` in the app.

**The TCC trap (read `spike/README.md` for the full writeup):** TCC checks the *responsible*
process, not the process that calls the API. A binary launched from a terminal is attributed to
the terminal, which has no `NSMotionUsageDescription`, and the process is `SIGABRT`'d before any
Swift error is raised: not a denial, a crash. The grant only sticks when the app is launched
through LaunchServices (Finder, Spotlight, `open -n PrivacyPods.app`). This is a hosting
constraint, not a bug: PrivacyPods can never be driven as a CLI tool.

**Without it:** `WearState` is permanently `.unknown(.permissionDenied)`. No gaze, no presence
walking evidence, nothing blurs, nothing locks.

## Screen Recording

**Why:** the overlay blurs a live low-fps `ScreenCaptureKit` capture of each display, not a
static color, so that whatever is actually on screen (video, changing content) stays hidden
rather than freezing on the first frame. Capturing requires Screen Recording.

**Requesting it:** macOS has no in-process prompt for this one on first use in some flows, and no
programmatic way to check status ahead of a doomed `SCStream` start beyond
`CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`, both wrapped by
`ScreenRecordingPermission` in `Overlay`. The auditor calls that wrapper; if the request does not
surface a system prompt (e.g. the process was already denied), it falls back to opening
`Permission.screenRecording.settingsURL`. Because preflight cannot tell "denied" from "never
asked", the auditor remembers in `UserDefaults` whether it has ever asked, and only then reports
`.denied` rather than `.notDetermined`.

**Without it:** `BlurMode.displaysToBlur` still decides a display should be blurred, but the
overlay has no frames to blur, so that display is covered blind: dark glass carrying the reason
from `CaptureAvailability`, never a silent black wall and never the live screen underneath. The
same value reaches the Status window through `AppCoordinator.captureAvailability`, so the
cover is always labelled rather than passing itself off as a working blur.

## Input Monitoring

**Why:** sustained typing is how PrivacyPods re-anchors a display while the user works, without
asking them to run a calibration step. Watching *global* key events (events sent to other apps,
not just PrivacyPods) requires Input Monitoring (or, on some configurations, Accessibility).
Pointer events reach the global monitor without it, so pointer bursts anchor either way.

**Requesting it:** `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` raises the system prompt
once per app identity; after that it returns immediately and the auditor falls back to opening
`Permission.inputMonitoring.settingsURL`, where the user adds PrivacyPods. No relaunch is needed.
Status comes from `IOHIDCheckAccess`, which (unlike `CGPreflightListenEventAccess`) distinguishes
"denied" from "never asked".

**Without it:** the global monitor is still installed and pointer events arrive, but keyboard
events do not reach it. Anchoring leans on pointer bursts and the re-anchor shortcut (⌃⌥⌘R by default), and
typing no longer resets the away timers; only pointer movement, the re-anchor shortcut and, indirectly, gaze
returning to `.looking` do. This is a real usability loss, not a crash: the app keeps working, it
just needs a manual nudge after long idle stretches. Since keyboard events only reach monitors
installed *after* the grant, `InputActivityMonitor` polls `CGPreflightListenEventAccess` every
five seconds while the permission is missing and reinstalls its monitors when it flips, so typing
starts counting within about five seconds of the grant with no relaunch.

## Bluetooth

**Why:** the proximity monitor lists paired devices through `IOBluetoothDevice.pairedDevices()`
to find the connected AirPods, and macOS gates that behind Bluetooth access
(`NSBluetoothAlwaysUsageDescription`). Proximity is a slow corroborating signal for walking
away, never a trigger on its own.

**Requesting it:** macOS asks the first time the monitor runs, which is when the AirPods are
first worn: `PresenceEngine` starts proximity on the first worn sample, so the prompt arrives in
context rather than the moment the app opens. The Status window reads the
state from `CBManager.authorization` without prompting; its button creates a
`CBCentralManager` while the state is undetermined (which raises the prompt once) and opens the
Bluetooth privacy pane after that.

**Without it:** walking away is judged from head motion and input alone. It degrades the app
rather than breaking it, so it never badges the menu bar icon.

## Checking status without a change notification

TCC does not notify processes when a grant changes underneath them, so `PermissionAuditing.refresh()`
re-reads every status. The Status window calls it every two seconds while it is open, and
the menu calls it each time it opens, since it lists unasked permissions (and a declined Screen
Recording while a display is covered blind) under the status line; a grant made in System
Settings therefore appears without relaunching. A Motion grant also restarts head tracking,
which had refused to start without it. `WindowController` drops a closed window instead of caching it, so the view
and its polling loop die with the window rather than running forever behind a window nobody can
see. Do not cache a status anywhere else.
