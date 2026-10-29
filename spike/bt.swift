import Foundation
import IOBluetooth

guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
    print("pairedDevices() returned nil or an unexpected type")
    exit(1)
}

print("paired devices: \(paired.count)")
for d in paired {
    let name = d.name ?? d.nameOrAddress ?? "<unnamed>"
    print("\n\(name)")
    print("  address:     \(d.addressString ?? "?")")
    print("  isConnected: \(d.isConnected())")
    print("  isPaired:    \(d.isPaired())")
    guard d.isConnected() else { continue }
    print("  rawRSSI():   \(d.rawRSSI())")
    print("  RSSI():      \(d.rssi())")
    print("  classOfDevice: 0x\(String(d.classOfDevice, radix: 16))")
}

// rawRSSI() can return a stale/zero value on the first read; poll to see whether
// a real dBm figure ever arrives for the connected AirPods.
print("\n--- polling connected devices ---")
let connected = paired.filter { $0.isConnected() }
for i in 1...5 {
    let line = connected.map { d in
        "\(d.name ?? "?")=raw:\(d.rawRSSI()) rssi:\(d.rssi())"
    }.joined(separator: "  |  ")
    print("poll \(i): \(line)")
    Thread.sleep(forTimeInterval: 0.4)
}
