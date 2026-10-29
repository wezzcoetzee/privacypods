# Permissions

PrivacyPods asks for three TCC permissions. Each is requested from the calibration window
(`Permission` in `Sources/PrivacyPods/Core/Permissions.swift`), which shows live status and a
button through to the right System Settings pane when the OS will not prompt in-process.

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
calibration window asks through `AppCoordinator.request(_:)`, which refuses while tracking is
already running — at which point the status is known anyway and the button is hidden. Once TCC has
answered, there is nothing left to prompt and the button opens the System Settings pane instead.
`HeadphoneMotionTracker.authorizationStatus` reports the current state without prompting, and is
the only reader of `CMHeadphoneMotionManager.authorizationStatus()` in the app.

**The TCC trap (read `spike/README.md` for the full writeup):** TCC checks the *responsible*
process, not the process that calls the API. A binary launched from a terminal is attributed to
the terminal, which has no `NSMotionUsageDescription`, and the process is `SIGABRT`'d before any
Swift error is raised — not a denial, a crash. The grant only sticks when the app is launched
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
same value reaches the calibration window through `AppCoordinator.captureAvailability`, so the
cover is always labelled rather than passing itself off as a working blur.

## Input Monitoring

**Why:** sustained keyboard or pointer bursts are how PrivacyPods re-anchors a display without
asking the user to run a calibration step. Watching *global* key and mouse events (events sent
to other apps, not just PrivacyPods) requires Input Monitoring (or, on some configurations,
Accessibility) so the `NSEvent` global monitor / `CGEvent` tap actually receives them.

**Requesting it:** `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` raises the system prompt
once per app identity; after that it returns immediately and the auditor falls back to opening
`Permission.inputMonitoring.settingsURL`, where the user adds PrivacyPods. No relaunch is needed.
Status comes from `IOHIDCheckAccess`, which (unlike `CGPreflightListenEventAccess`) distinguishes
"denied" from "never asked".

**Without it:** the global monitor is still installed and pointer events arrive, but keyboard
events do not reach it. Anchoring leans on pointer bursts and the hotkey (⌃⌥⌘R by default), and
typing no longer resets the away timers; only pointer movement, the hotkey and, indirectly, gaze
returning to `.looking` do. This is a real usability loss, not a crash: the app keeps working, it
just needs a manual nudge after long idle stretches. Since keyboard events only reach monitors
installed *after* the grant, `InputActivityMonitor` polls `CGPreflightListenEventAccess` every
five seconds while the permission is missing and reinstalls its monitors when it flips, so typing
starts counting within about five seconds of the grant with no relaunch.

## Checking status without a change notification

TCC does not notify processes when a grant changes underneath them, so `PermissionAuditing.refresh()`
re-reads all three statuses. The calibration view calls it every two seconds while it is open,
which is the only place the app shows a status; a grant made in System Settings therefore appears
without relaunching. `WindowController` drops a closed window instead of caching it, so the view
and its polling loop die with the window rather than running forever behind a window nobody can
see. Do not cache a status anywhere else.
