import AppKit
import CoreImage
import Foundation
import Testing
@testable import PrivacyPods

/// Renders every user-facing surface in a fixed set of states and writes PNGs, so UI changes can
/// be reviewed as pictures. Not a test: it asserts nothing and only runs when asked.
///
///     scripts/snapshots.sh <output-dir>
///
/// The coordinator runs against fakes, so nothing here reads a sensor, blurs a real display or
/// locks the Mac. Windows and menus do appear on screen for a moment while they are captured.
@MainActor
@Suite("UI snapshots", .enabled(if: snapshotDirectory != nil), .serialized)
struct UISnapshots {
    @Test("Render every surface")
    func renderAll() async throws {
        let directory = try #require(snapshotDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)

        for scenario in Scenario.all {
            let world = await World(scenario)
            if scenario.surfaces.contains(.menu) {
                await world.captureMenu(
                    to: directory.appending(path: "menu-\(scenario.name).png"),
                    icon: directory.appending(path: "icon-\(scenario.name).png")
                )
            }
            if scenario.surfaces.contains(.settings) {
                await world.captureWindow(to: directory.appending(path: "settings-\(scenario.name).png")) {
                    $0.showSettings()
                }
            }
            if scenario.surfaces.contains(.status) {
                await world.captureWindow(to: directory.appending(path: "status-\(scenario.name).png")) {
                    $0.showStatus()
                }
            }
            world.tearDown()
        }

        let hotkey = Hotkey.reanchorDefault.label
        let noHeadData = AppCoordinator.overlayNotice(
            gaze: .unknown, wearState: .unknown(.sampleGap), awayResponse: .idle, hotkey: hotkey, canType: true
        )
        await captureOverlay(blurred: true, to: directory.appending(path: "overlay-blurred.png"))
        await captureOverlay(blurred: true, reason: noHeadData, to: directory.appending(path: "overlay-no-head-data.png"))
        let unanchored = AppCoordinator.overlayNotice(
            gaze: .away, wearState: .worn, awayResponse: .idle, hotkey: hotkey, canType: true, displayIsAnchored: false
        )
        await captureOverlay(blurred: true, reason: unanchored, to: directory.appending(path: "overlay-unanchored.png"))
        await captureOverlay(
            blurred: false,
            notice: CaptureAvailability.unavailable(.screenRecordingDenied).notice,
            to: directory.appending(path: "overlay-blind.png")
        )
        await captureOverlay(
            blurred: false,
            reason: noHeadData,
            notice: CaptureAvailability.unavailable(.screenRecordingDenied).notice,
            to: directory.appending(path: "overlay-blind-no-head-data.png")
        )
        Screen.finish()
    }

    private func captureOverlay(blurred: Bool, reason: String? = nil, notice: String? = nil, to url: URL) async {
        let frame = CGRect(x: 120, y: 160, width: 1280, height: 800)
        let window = BlurOverlayWindow(frame: frame)
        window.sharingType = .readOnly
        window.alphaValue = 1
        if blurred { window.render(FakeScreen.blurred(size: frame.size)) }
        window.show(reason: reason)
        window.show(notice: notice)
        window.orderFrontRegardless()
        await settle()
        Screen.capture(window: window.windowNumber, to: url)
        window.orderOut(nil)
        window.close()
    }
}

private let snapshotDirectory = ProcessInfo.processInfo.environment["PRIVACYPODS_SNAPSHOT_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

// MARK: - Scenarios

@MainActor
private struct Scenario {
    enum Surface { case menu, settings, status }

    var name: String
    var surfaces: Set<Surface>
    var wear: WearState = .worn
    var gaze: (DisplayID) -> GazeState = { .looking($0) }
    var presence: PresenceState = .present
    var capture: CaptureAvailability = .available
    var permissions: [Permission: PermissionStatus] = [.motion: .granted, .screenRecording: .granted, .inputMonitoring: .granted, .bluetooth: .granted]
    var anchored: Bool = true
    /// Only the first display anchored, as after an unlock when only one has been typed on.
    var onlyFirstAnchored = false
    var pose: HeadPose? = HeadPose(yaw: Degrees(-3.4), pitch: Degrees(1.2))
    /// Most scenarios are past setup; first run is the one that is not.
    var lockTested = true
    var failsToLock = false
    /// Back at the desk after the away state, as the owner opening the menu would be.
    var returned = false
    var hotkeyTaken = false
    var configure: (inout AppSettings) -> Void = { _ in }

    static let all: [Scenario] = [
        Scenario(name: "first-run", surfaces: [.menu, .status],
                 wear: .unknown(.noHeadphonesConnected), gaze: { _ in .unknown },
                 presence: .unknown,
                 permissions: [.motion: .notDetermined, .screenRecording: .notDetermined, .inputMonitoring: .notDetermined, .bluetooth: .notDetermined],
                 anchored: false, pose: nil, lockTested: false),
        Scenario(name: "tracking", surfaces: [.menu, .settings, .status]),
        Scenario(name: "not-anchored", surfaces: [.menu], gaze: { _ in .unknown }, anchored: false),
        Scenario(name: "looking-away", surfaces: [.menu], gaze: { _ in .away }),
        Scenario(name: "sample-gap", surfaces: [.menu], wear: .unknown(.sampleGap), gaze: { _ in .unknown }, pose: nil),
        Scenario(name: "sample-gap-covered", surfaces: [.menu], wear: .unknown(.sampleGap), gaze: { _ in .unknown }, pose: nil,
                 configure: { $0.failMode = .closed }),
        Scenario(name: "paused-hour", surfaces: [.menu],
                 configure: { $0.isEnabled = false; $0.resumeAt = Date().addingTimeInterval(3600) }),
        Scenario(name: "lock-failed", surfaces: [.menu], gaze: { _ in .away },
                 presence: .away(since: .distantPast), failsToLock: true,
                 configure: { $0.awayPolicy = .lockImmediately }),
        Scenario(name: "lock-failed-returned", surfaces: [.menu, .status],
                 presence: .away(since: .distantPast), failsToLock: true, returned: true,
                 configure: { $0.awayPolicy = .lockImmediately }),
        Scenario(name: "disabled", surfaces: [.menu], configure: { $0.isEnabled = false }),
        Scenario(name: "unanchored-display", surfaces: [.menu, .status], gaze: { _ in .away }, onlyFirstAnchored: true),
        Scenario(name: "degraded", surfaces: [.settings, .status],
                 capture: .unavailable(.screenRecordingDenied),
                 permissions: [.motion: .granted, .screenRecording: .denied, .inputMonitoring: .denied, .bluetooth: .granted],
                 hotkeyTaken: true),
    ]
}

/// A coordinator wired to fakes and put into one scenario's state.
@MainActor
private final class World {
    let coordinator: AppCoordinator
    let windows: WindowController
    private let defaultsSuite = "dev.wesley.privacypods.snapshots"
    private var blocker: ReanchorHotkeyMonitor?

    init(_ scenario: Scenario) async {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        var settings = AppSettings()
        settings.lockTested = scenario.lockTested
        // Past setup, the first-run Launch at login offer has already been shown.
        settings.launchAtLoginOffered = scenario.lockTested
        scenario.configure(&settings)
        defaults.set(try! JSONEncoder().encode(settings), forKey: AppSettings.defaultsKey)

        let displays = DisplayInfo.current()
        let primary = displays[0].id
        let head = FakeHeadTracking(scenario.wear)
        let gaze = FakeGaze(scenario.gaze(primary))
        if scenario.anchored {
            for (index, display) in displays.enumerated() where !(scenario.onlyFirstAnchored && index > 0) {
                gaze.anchor(display.id, source: index == 0 ? .sustainedInput : .hotkey)
            }
        }
        let presence = FakePresence(.present)

        if scenario.hotkeyTaken {
            let blocker = ReanchorHotkeyMonitor()
            _ = blocker.register(settings.reanchorHotkey)
            self.blocker = blocker
        }

        coordinator = AppCoordinator(
            headTracking: head,
            inputActivity: FakeInput(),
            hotkey: ReanchorHotkeyMonitor(),
            gaze: gaze,
            overlay: FakeOverlay(scenario.capture),
            presence: presence,
            screenLock: FakeScreenLock(succeeds: !scenario.failsToLock),
            permissions: FakePermissions(scenario.permissions),
            settings: SettingsStore(defaults: defaults)
        )
        windows = WindowController(coordinator: coordinator)
        coordinator.start()

        if let pose = scenario.pose {
            head.send(.sample(MotionSample(pose: pose, userAcceleration: Vector3(x: 0, y: 0, z: 0), timestamp: Date())))
        }
        if scenario.presence != .present { presence.send(scenario.presence) }
        if scenario.returned {
            await settle()
            presence.send(.present)
        }
        await settle()
    }

    /// Captures the status item's icon and its open menu, each by window, so nothing else on
    /// screen can end up in the picture.
    func captureMenu(to url: URL, icon iconURL: URL) async {
        let controller = StatusItemController(coordinator: coordinator, windows: windows)
        await settle()
        guard let menu = controller.statusItem.menu else { return }
        Screen.write(controller.statusItem.button?.image, dimmed: controller.statusItem.button?.appearsDisabled == true, to: iconURL)

        // A menu still owned by its status item will not pop up anywhere else.
        controller.statusItem.menu = nil
        // `popUp` runs the menu's tracking loop and only returns once the menu closes, so the
        // capture is scheduled on a timer that fires in the tracking run loop mode.
        nonisolated(unsafe) let trackedMenu = menu
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .popUpMenu }) {
                    Screen.capture(window: window.windowNumber, to: url)
                }
                trackedMenu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Mid-screen rather than under the status item: near the top edge AppKit scrolls the menu
        // instead of showing all of it.
        let visible = NSScreen.screens[0].visibleFrame
        menu.popUp(positioning: nil, at: NSPoint(x: visible.midX, y: visible.midY + 200), in: nil)
        await settle()
        NSStatusBar.system.removeStatusItem(controller.statusItem)
    }

    func captureWindow(to url: URL, open: (WindowController) -> Void) async {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        open(windows)
        await settle(seconds: 0.8)
        guard let window = NSApp.windows.first(where: {
            !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.styleMask.contains(.titled)
        }) else { return }
        Screen.capture(window: window.windowNumber, to: url)
        window.close()
        await settle()
    }

    func tearDown() {
        coordinator.stop()
        blocker?.unregister()
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }
}

@MainActor
private func settle(seconds: Double = 0.4) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// Captures go through `scripts/snapshots.sh`, which runs `screencapture` on the harness's behalf:
/// the test host is a freshly signed build without Screen Recording, and the shell that launched
/// it usually has it. A request is one argument per line in `.request`; the script deletes the
/// file once the capture is written.
@MainActor
private enum Screen {
    static func capture(window: Int, to url: URL) {
        request(["-x", "-o", "-l", String(window), url.path])
    }

    /// The status item's icon, drawn as the menu bar would in dark mode.
    static func write(_ image: NSImage?, dimmed: Bool, to url: URL) {
        guard let image else { return }
        let scale = 4.0
        let size = NSSize(width: 44, height: 30)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.withAlphaComponent(dimmed ? 0.4 : 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: (size.width - image.size.width) / 2, y: (size.height - image.size.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func finish() {
        guard let directory = snapshotDirectory else { return }
        FileManager.default.createFile(atPath: directory.appending(path: ".done").path, contents: nil)
    }

    /// Blocks the main thread until the script has taken the picture: the menu capture runs
    /// inside a tracking loop where awaiting is not an option, and nothing needs to move meanwhile.
    private static func request(_ arguments: [String]) {
        guard let directory = snapshotDirectory else { return }
        let file = directory.appending(path: ".request")
        try? arguments.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: file.path) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

/// A made-up document to stand in for the screen behind the overlay, so no real screen content
/// ever ends up in a snapshot.
private enum FakeScreen {
    static func blurred(size: CGSize) -> CGImage {
        let scale = 2.0
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 120, width: width, height: 120))
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 160, y: height - 420, width: 900, height: 200))
        for row in 0..<22 {
            let y = height - 520 - row * 70
            let length = [2000, 1800, 2100, 1500, 1900][row % 5]
            context.setFillColor(CGColor(gray: 0.25, alpha: 1))
            context.fill(CGRect(x: 160, y: y, width: length, height: 26))
        }
        let source = CIImage(cgImage: context.makeImage()!)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 70 * scale).cropped(to: source.extent)
        return CIContext().createCGImage(blurred, from: source.extent)!
    }
}

// MARK: - Fakes

@MainActor
private final class FakeHeadTracking: HeadTrackingProviding {
    let events: AsyncStream<HeadTrackingEvent>
    private let continuation: AsyncStream<HeadTrackingEvent>.Continuation
    var wearState: WearState

    init(_ wearState: WearState) {
        self.wearState = wearState
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ event: HeadTrackingEvent) { continuation.yield(event) }
    func start() {}
    func stop() {}
}

@MainActor
private final class FakeInput: InputActivityProviding {
    let events = AsyncStream<InputActivity> { _ in }
    func start() {}
    func stop() {}
}

@MainActor
private final class FakeGaze: GazeClassifying {
    let state: GazeState
    let events = AsyncStream<GazeState> { _ in }
    private(set) var anchors: [DisplayID: DisplayAnchor] = [:]

    init(_ state: GazeState) { self.state = state }

    func ingest(_ event: HeadTrackingEvent) {}
    func anchor(_ display: DisplayID, source: DisplayAnchor.Source) {
        anchors[display] = DisplayAnchor(display: display, pose: .zero, capturedAt: Date(), source: source)
    }
    func retainOnly(_ displays: Set<DisplayID>) {}
    func update(cone: AcceptanceCone, awayGrace: TimeInterval) {}
}

@MainActor
private final class FakeOverlay: OverlayControlling {
    let captureAvailability: CaptureAvailability
    let captureEvents = AsyncStream<CaptureAvailability> { _ in }
    init(_ availability: CaptureAvailability) { captureAvailability = availability }
    func setBlurred(_ displays: Set<DisplayID>, radius: Double, notices: [DisplayID: String]) {}
    func teardown() {}
}

@MainActor
private final class FakePresence: PresenceProviding {
    var state: PresenceState
    let events: AsyncStream<PresenceState>
    private let continuation: AsyncStream<PresenceState>.Continuation

    init(_ state: PresenceState) {
        self.state = state
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ state: PresenceState) {
        self.state = state
        continuation.yield(state)
    }

    func ingest(_ event: HeadTrackingEvent) {}
    func ingest(_ activity: InputActivity) {}
    func ingest(gaze: GazeState) {}
    func start() {}
    func stop() {}
}

@MainActor
private final class FakeScreenLock: ScreenLocking {
    let isLocked = false
    let events = AsyncStream<Bool> { _ in }
    private let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func lock() -> Bool { succeeds }
}

@MainActor
private final class FakePermissions: PermissionAuditing {
    private let statuses: [Permission: PermissionStatus]
    init(_ statuses: [Permission: PermissionStatus]) { self.statuses = statuses }
    func status(of permission: Permission) -> PermissionStatus { statuses[permission] ?? .notDetermined }
    func request(_ permission: Permission) {}
    func refresh() {}
}
