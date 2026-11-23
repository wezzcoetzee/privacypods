import Foundation
import IOBluetooth

/// Deliberately coarse: the only source that works on macOS 26 is a ~1 s subprocess, so this can
/// corroborate walking away but never be what notices it.
enum ProximityTrend: Hashable, Sendable {
    case unavailable
    case steady
    case falling
}

/// `IOBluetoothDevice.rawRSSI()` returns 0 for every connected device on macOS 26, a "no data"
/// sentinel with no error (see `spike/README.md`). IOBluetooth still enumerates devices; the
/// number comes from `system_profiler`, a slow subprocess. If nothing answers, the monitor logs
/// once and stops polling.
@MainActor
final class BluetoothProximityMonitor {
    private static let pollInterval: TimeInterval = 1
    /// `system_profiler` costs about a second of CPU.
    private static let fallbackPollInterval: TimeInterval = 5
    /// Consecutive empty `system_profiler` reads before giving up for the session.
    private static let fallbackMissLimit = 5
    private static let trendWindow: TimeInterval = 20
    /// dBm drop between the older and newer half of the window. Large because RSSI is noisy indoors.
    private static let fallingBy: Double = 6

    private enum Source {
        case ioBluetooth
        case systemProfiler
    }

    /// From the SDP device-identification record.
    private static let appleVendorID = 0x004C

    private var readings: [(time: Date, rssi: Int)] = []
    private var source: Source = .ioBluetooth
    private var task: Task<Void, Never>?
    private var fallbackMisses = 0
    private var followedAddress: String?
    /// Bumped by `stop()`, so a slow `system_profiler` answer cannot resurrect a stopped monitor.
    private var generation = 0

    private(set) var trend: ProximityTrend = .unavailable

    func start() {
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = await self.poll(generation: generation) else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        clearReadings()
    }

    /// Returns the delay before the next poll, or `nil` to stop polling.
    private func poll(generation: Int) async -> TimeInterval? {
        guard let device = connectedHeadphones() else {
            clearReadings()
            return Self.fallbackPollInterval
        }

        if source == .ioBluetooth {
            if let rssi = usableRSSI(device.rawRSSI()) {
                record(rssi)
                return Self.pollInterval
            }
            source = .systemProfiler
            Log.presence.notice("IOBluetooth RSSI is unavailable on this system; falling back to system_profiler")
        }

        let address = device.addressString ?? ""
        let rssi = await Task.detached(priority: .utility) {
            SystemProfilerBluetooth.rssi(forAddress: address)
        }.value

        guard generation == self.generation else { return nil }

        guard let rssi else {
            // Includes a timed-out read, so a wedged Bluetooth stack cannot freeze the trend at `.falling`.
            clearReadings()
            fallbackMisses += 1
            guard fallbackMisses < Self.fallbackMissLimit else {
                Log.presence.notice("system_profiler gave no RSSI \(self.fallbackMisses, privacy: .public) times; carrying on without proximity")
                return nil
            }
            return Self.fallbackPollInterval
        }

        fallbackMisses = 0
        record(rssi)
        return Self.fallbackPollInterval
    }

    /// CoreMotion never names its source, so this approximates it: connected, audio class, and
    /// preferably Apple's vendor ID, which separates AirPods from a paired speaker.
    private func connectedHeadphones() -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        // Match on class and connection state, not on name: AirPods keep stale pairing records
        // that share a name with the live one.
        let audio = paired.filter {
            $0.isConnected() && $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio)
        }

        guard let chosen = audio.first(where: isApple) ?? audio.first else {
            followedAddress = nil
            return nil
        }
        if chosen.addressString != followedAddress {
            followedAddress = chosen.addressString
            Log.presence.notice("Proximity is following \(chosen.nameOrAddress ?? "an unnamed device", privacy: .public)")
        }
        return chosen
    }

    private func isApple(_ device: IOBluetoothDevice) -> Bool {
        let pnpInformation = IOBluetoothSDPUUID(uuid16: BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassPnPInformation.rawValue))
        let vendorID = BluetoothSDPServiceAttributeID(kBluetoothSDPAttributeDeviceIdentifierVendorID.rawValue)
        guard let record = device.getServiceRecord(for: pnpInformation),
            let vendor = record.getAttributeDataElement(vendorID)?.getNumberValue()
        else { return false }
        return vendor.intValue == Self.appleVendorID
    }

    /// 0 and 127 are both "no data" markers.
    private func usableRSSI(_ raw: BluetoothHCIRSSIValue) -> Int? {
        let value = Int(raw)
        return value == 0 || value == 127 ? nil : value
    }

    private func clearReadings() {
        readings.removeAll()
        trend = .unavailable
    }

    private func record(_ rssi: Int) {
        let now = Date()
        readings.append((now, rssi))
        let cutoff = now.addingTimeInterval(-Self.trendWindow)
        readings.removeAll { $0.time < cutoff }
        trend = currentTrend()
    }

    private func currentTrend() -> ProximityTrend {
        guard readings.count >= 4,
            let first = readings.first, let last = readings.last,
            last.time.timeIntervalSince(first.time) >= Self.trendWindow / 4
        else { return .steady }

        let split = readings.count / 2
        let older = mean(readings.prefix(split).map(\.rssi))
        let newer = mean(readings.suffix(readings.count - split).map(\.rssi))
        return newer - older <= -Self.fallingBy ? .falling : .steady
    }

    private func mean(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

private enum SystemProfilerBluetooth {
    /// It normally answers in about a second; much past that is a wedged Bluetooth stack.
    private static let timeout: TimeInterval = 3

    private struct Report: Decodable {
        struct Controller: Decodable {
            let connected: [[String: Device]]?

            enum CodingKeys: String, CodingKey {
                case connected = "device_connected"
            }
        }

        struct Device: Decodable {
            let address: String?
            let rssi: String?

            enum CodingKeys: String, CodingKey {
                case address = "device_address"
                case rssi = "device_rssi"
            }
        }

        let controllers: [Controller]

        enum CodingKeys: String, CodingKey {
            case controllers = "SPBluetoothDataType"
        }
    }

    /// Blocking for up to `timeout`. Call it off the main actor.
    static func rssi(forAddress address: String) -> Int? {
        guard !address.isEmpty, let data = run() else { return nil }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            Log.presence.error("Could not parse system_profiler Bluetooth output")
            return nil
        }

        let wanted = normalize(address)
        let devices = report.controllers.flatMap { $0.connected ?? [] }.flatMap(\.values)
        return
            devices
            .first { $0.address.map(normalize) == wanted }
            .flatMap { $0.rssi }
            .flatMap(Int.init)
    }

    private static func run() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.presence.error("system_profiler failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let watchdog = ProcessWatchdog(process, after: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if watchdog.cancel() {
            Log.presence.error("system_profiler exceeded its deadline and was terminated")
            return nil
        }
        return process.terminationStatus == 0 ? data : nil
    }

    /// IOBluetooth writes `68-a5-93-5e-50-5b`, system_profiler writes `68:A5:93:5E:50:5B`.
    private static func normalize(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }
}

/// Kills a subprocess that outruns its deadline, releasing a caller blocked on its pipe.
/// `terminate()` is the only `Process` call made off-thread, and it is documented as safe there.
private final class ProcessWatchdog: @unchecked Sendable {
    private enum Outcome {
        case pending
        case fired
        case cancelled
    }

    private let process: Process
    private let lock = NSLock()
    private var outcome: Outcome = .pending
    private var work: DispatchWorkItem?

    init(_ process: Process, after timeout: TimeInterval) {
        self.process = process
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        self.work = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Reports whether the watchdog already killed the process. Claiming the outcome under the
    /// lock stops a simultaneous fire from signalling a process the caller has already reaped.
    func cancel() -> Bool {
        work?.cancel()
        work = nil
        return lock.withLock {
            if outcome == .pending { outcome = .cancelled }
            return outcome == .fired
        }
    }

    private func fire() {
        lock.withLock {
            guard outcome == .pending else { return }
            outcome = .fired
            process.terminate()
        }
    }
}
