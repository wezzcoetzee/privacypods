import CoreMotion
import Foundation

// Output is tee'd to a file so the run is readable whether the binary is
// launched directly or via `open` (which detaches stdout).
let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOTION_LOG"]
    ?? "/tmp/privacypods-motion.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)

func log(_ message: String) {
    print(message)
    fflush(stdout)
    logHandle?.write(Data((message + "\n").utf8))
}

let deg = 180.0 / Double.pi

func statusName(_ s: CMAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    @unknown default:    return "unknown(\(s.rawValue))"
    }
}

log("bundleIdentifier:        \(Bundle.main.bundleIdentifier ?? "<none>")")
log("bundlePath:              \(Bundle.main.bundlePath)")
log("NSMotionUsageDescription present: "
    + "\(Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil)")

// Both of these hit TCC and abort the process if the usage description is absent.
log("authorizationStatus:     \(statusName(CMHeadphoneMotionManager.authorizationStatus()))")

let manager = CMHeadphoneMotionManager()
log("isDeviceMotionAvailable: \(manager.isDeviceMotionAvailable)")

var samples = 0
var lastPrint = Date.distantPast
let started = Date()
let duration: TimeInterval = 15

let queue = OperationQueue()
queue.maxConcurrentOperationCount = 1

manager.startDeviceMotionUpdates(to: queue) { motion, error in
    if let error {
        let ns = error as NSError
        log("handler error: \(ns.domain) code=\(ns.code) \(ns.localizedDescription)")
        return
    }
    guard let motion else { return }
    samples += 1
    guard Date().timeIntervalSince(lastPrint) >= 0.5 else { return }
    lastPrint = Date()
    let a = motion.attitude
    let u = motion.userAcceleration
    log(String(format: "t=%5.2f  yaw=%+8.2f pitch=%+8.2f roll=%+8.2f  accel=(%+.3f, %+.3f, %+.3f)",
               Date().timeIntervalSince(started),
               a.yaw * deg, a.pitch * deg, a.roll * deg,
               u.x, u.y, u.z))
}

log("startDeviceMotionUpdates called; isDeviceMotionActive=\(manager.isDeviceMotionActive)")

RunLoop.current.run(until: Date().addingTimeInterval(duration))
manager.stopDeviceMotionUpdates()

log("--- done ---")
log("samples: \(samples)")
log("final authorizationStatus: \(statusName(CMHeadphoneMotionManager.authorizationStatus()))")
try? logHandle?.close()
