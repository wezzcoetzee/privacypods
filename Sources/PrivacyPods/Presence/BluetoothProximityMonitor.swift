import Foundation
import IOBluetooth

/// Which way the AirPods' signal strength is heading.
///
/// Deliberately coarse. The only reading source that works on macOS 26 is a ~1 second
/// subprocess, so this can corroborate "walking away" but can never be the thing that notices it.
enum ProximityTrend: Hashable, Sendable {
    /// No connected AirPods, or no source willing to give a number.
    case unavailable
    case steady
    case falling
}

/// Polls the connected AirPods' RSSI and reports the trend.
///
/// `IOBluetoothDevice.rawRSSI()` returns 0 for every connected device on macOS 26 — a "no data"
/// sentinel, not a reading, and it raises no error (see `spike/README.md`). So IOBluetooth is
/// used for what it is still good at, enumerating devices, and the number comes from
/// `system_profiler`, which does return a live value at the cost of a slow subprocess. Proximity
/// is optional corroboration throughout: if nothing answers, the monitor logs once, says
/// `.unavailable` and stops spending subprocesses on it.
@MainActor
final class BluetoothProximityMonitor {
    struct Configuration: Hashable, Sendable {
        var pollInterval: TimeInterval = 1
        /// `system_profiler` costs about a second of CPU, so it gets its own slower cadence.
        var fallbackPollInterval: TimeInterval = 5
        /// Consecutive empty `system_profiler` reads before the monitor gives up for the rest of
        /// the session. A radio that will not report is worth one log line, not a subprocess
        /// every five seconds forever.
        var fallbackMissLimit = 5
        /// How much of the recent history the trend is read from.
        var trendWindow: TimeInterval = 20
        /// Drop in dBm, comparing the older half of the window to the newer, that counts as
        /// walking away. Signal strength is noisy indoors; this is a deliberately large step.
        var fallingBy: Double = 6

        static let `default` = Configuration()
    }

    private enum Source {
        case ioBluetooth
        case systemProfiler
    }

    /// Apple's Bluetooth vendor ID, as published in the SDP device-identification record.
    private static let appleVendorID = 0x004C

    private let configuration: Configuration
    private let timeSource: any TimeSource
    private var readings: [(time: Date, rssi: Int)] = []
    private var source: Source = .ioBluetooth
    private var task: Task<Void, Never>?
    private var fallbackMisses = 0
    private var followedAddress: String?
    /// Bumped by `stop()`. A `system_profiler` read can be several seconds out; stamping the poll
    /// that started it lets the answer be dropped instead of resurrecting a stopped monitor.
    private var generation = 0

    private(set) var trend: ProximityTrend = .unavailable

    init(configuration: Configuration = .default, timeSource: any TimeSource = SystemTimeSource()) {
        self.configuration = configuration
        self.timeSource = timeSource
    }

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

    /// Takes one reading and returns how long to wait before the next, or `nil` when there is
    /// nothing left worth polling for.
    private func poll(generation: Int) async -> TimeInterval? {
        guard let device = connectedHeadphones() else {
            clearReadings()
            return configuration.fallbackPollInterval
        }

        if source == .ioBluetooth {
            if let rssi = usableRSSI(device.rawRSSI()) {
                record(rssi)
                return configuration.pollInterval
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
            // A miss includes a timed-out read, so a wedged Bluetooth stack cannot leave the
            // trend frozen at `.falling` while the away rules keep reading it.
            clearReadings()
            fallbackMisses += 1
            guard fallbackMisses < configuration.fallbackMissLimit else {
                Log.presence.notice("system_profiler gave no RSSI \(self.fallbackMisses, privacy: .public) times; carrying on without proximity")
                return nil
            }
            return configuration.fallbackPollInterval
        }

        fallbackMisses = 0
        record(rssi)
        return configuration.fallbackPollInterval
    }

    /// The connected device the head samples are most likely coming from.
    ///
    /// CoreMotion never names its source, so the pick is the closest honest approximation:
    /// connected, audio class, and Apple's vendor ID in the SDP device-identification record,
    /// which is what separates AirPods from the Bluetooth speaker also paired to this Mac.
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

    /// 0 dBm would mean the transmitter is touching the antenna and 127 is the classic
    /// "unavailable" marker; both mean "no data" here.
    private func usableRSSI(_ raw: BluetoothHCIRSSIValue) -> Int? {
        let value = Int(raw)
        return value == 0 || value == 127 ? nil : value
    }

    private func clearReadings() {
        readings.removeAll()
        trend = .unavailable
    }

    private func record(_ rssi: Int) {
        let now = timeSource.now
        readings.append((now, rssi))
        let cutoff = now.addingTimeInterval(-configuration.trendWindow)
        readings.removeAll { $0.time < cutoff }
        trend = currentTrend()
    }

    private func currentTrend() -> ProximityTrend {
        guard readings.count >= 4,
              let first = readings.first, let last = readings.last,
              last.time.timeIntervalSince(first.time) >= configuration.trendWindow / 4
        else { return .steady }

        let split = readings.count / 2
        let older = mean(readings.prefix(split).map(\.rssi))
        let newer = mean(readings.suffix(readings.count - split).map(\.rssi))
        return newer - older <= -configuration.fallingBy ? .falling : .steady
    }

    private func mean(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

/// The only Bluetooth signal-strength source that still answers on macOS 26.
private enum SystemProfilerBluetooth {
    /// `system_profiler` normally answers in about a second. Anything much past that is a wedged
    /// Bluetooth stack rather than a slow machine, and waiting it out would strand the poll.
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

    /// Blocking, roughly a second and never more than `timeout`. Call it off the main actor.
    static func rssi(forAddress address: String) -> Int? {
        guard !address.isEmpty, let data = run() else { return nil }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            Log.presence.error("Could not parse system_profiler Bluetooth output")
            return nil
        }

        let wanted = normalize(address)
        let devices = report.controllers.flatMap { $0.connected ?? [] }.flatMap(\.values)
        return devices
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

/// Kills a subprocess that outruns its deadline, so a caller blocked on its pipe is released.
///
/// `Process` is not `Sendable`; `terminate()` is the one thing this touches from another thread
/// and it is documented as safe there.
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

    /// Stops the watchdog and reports whether it had already killed the process. Claiming the
    /// outcome under the lock is what stops a watchdog that fired at the same instant from
    /// signalling `terminate()` at a process the caller has already reaped.
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
