# Spike: AirPods head tracking + Bluetooth RSSI on macOS

Ran 2026-09-21 on macOS 26.6.2 (arm64), Swift 6.4, AirPods Pro (firmware 9A348) worn and connected.

Both questions are answered: **head tracking works, and RSSI works — but not through the API we expected.**

## 1. Head tracking (CoreMotion)

Works. ~49 Hz of real attitude data.

```
authorizationStatus:     authorized
isDeviceMotionAvailable: true
t= 0.74  yaw= -137.68 pitch=   +7.69 roll=  +11.87  accel=(+0.016, +0.024, -0.006)
...
samples: 735          # 15 s run
```

Observed while Wesley sat at the desk: yaw -162.3..-110.1 (52 deg span), pitch +2.2..+32.7,
roll +0.8..+93.5. The first sample of each run is garbage (roll ~+93, accel ~1 g) and settles
within ~2 samples, so discard it. `userAcceleration` sits around ±0.01 g at rest and spikes on
head movement.

### The TCC trap (this is the real finding)

`CMHeadphoneMotionManager` is gated by `kTCCServiceMotion`, and a process without
`NSMotionUsageDescription` does not get an error — it is **SIGABRT'd by TCC**, with stdout lost.
Exit code 134, `namespace: "TCC"`, no Swift error ever reaches your handler.

Three escalating states we hit:

| How it was run | Result |
| --- | --- |
| Bare `swiftc` binary, no bundle | Abort at `authorizationStatus()`. No usage description. |
| Binary inside `.app`, run from the terminal | `isDeviceMotionAvailable: true`, then abort at `startDeviceMotionUpdates`. |
| `.app` launched with `open -n` | Prompt shown, allowed, 735 samples. |

The middle row is the subtle one. TCC does not check the *calling* process, it checks the
**responsible process**. Launched from a terminal, the crash report shows
`respProc: T3 Code (Nightly)` — TCC looked at the terminal emulator's Info.plist, found no
`NSMotionUsageDescription`, and killed us. The bundle's own plist was ignored.

Launching through LaunchServices (`open -n`) makes the app responsible for itself, so the prompt
appears and the grant is recorded against `com.wcoetzee.privacypods.spike`. The grant persists:
a relaunch reports `authorized` at t=0 with no prompt. **But it only applies to the LaunchServices
path** — running the same binary directly from the terminal still reports `notDetermined` and still
aborts, because the responsible process is the terminal again.

Implications for the real app: it must ship as a signed `.app` with `NSMotionUsageDescription`, and
it can never be driven as a CLI from a terminal. For local iteration, `open -n Foo.app` and tee
output to a file (what `motion.swift` does via `MOTION_LOG`).

`isDeviceMotionAvailable` returned `true` even while unauthorized, so it reports "AirPods with a
gyro are connected", not "you may read them". Don't use it as a permission check.

## 2. Bluetooth RSSI (IOBluetooth)

Enumeration works, **RSSI does not**.

`IOBluetoothDevice.pairedDevices()` returned 15 devices with correct names, addresses, and
`isConnected()`. The connected AirPods are `68-a5-93-5e-50-5b` (a second stale pairing record,
`ac-1d-06-9c-db-9d`, also shows up — match on the connected one, not the name).

But on every connected device, `rawRSSI()` and `RSSI()` both return **0**, polled 5x over 2 s:

```
poll 1: AirPods Pro=raw:0 rssi:0  |  MX Master 3S=raw:0 rssi:0  |  MX MCHNCL M=raw:0 rssi:0
...
poll 5: AirPods Pro=raw:0 rssi:0  |  MX Master 3S=raw:0 rssi:0  |  MX MCHNCL M=raw:0 rssi:0
```

0 is not a plausible reading (0 dBm is transmitter-adjacent) and it is identical across three
unrelated devices, so this is a "no data" sentinel, not a measurement. No error is raised. This
API appears to be dead on modern macOS.

### What does work

`system_profiler SPBluetoothDataType -json` returns a real, live value:

```
Wesley's AirPods Pro: connected=True rssi=-57 addr=68:A5:93:5E:50:5B
```

It tracked movement across runs (-45, then -57), so it is a live measurement rather than a cached
constant. Downside: it is a ~1 s subprocess, so it is a poll-at-low-rate source, not something to
sample at motion rates. Good enough for coarse proximity; not good enough for anything responsive.

## Files

- `motion.swift` — head tracking probe. Tees to `$MOTION_LOG` (default `/tmp/privacypods-motion.log`).
- `bt.swift` — paired-device enumeration + RSSI attempts.
- `HeadphoneMotionSpike.app` — minimal bundle (Info.plist + ad-hoc signature) that TCC will prompt for.

## Repro

```sh
swiftc -O motion.swift -o motion -framework CoreMotion
swiftc -O bt.swift -o bt -framework IOBluetooth

./bt                                  # works from the terminal
open -n ./HeadphoneMotionSpike.app    # motion MUST go through LaunchServices
sleep 16 && cat /tmp/privacypods-motion.log
```

To rebuild the bundle after editing `motion.swift`:

```sh
swiftc -O motion.swift -o HeadphoneMotionSpike.app/Contents/MacOS/HeadphoneMotionSpike \
  -framework CoreMotion
codesign --force --deep --sign - HeadphoneMotionSpike.app
```

Re-signing keeps the same bundle id, so the existing TCC grant survives. Changing
`CFBundleIdentifier` would re-prompt.
