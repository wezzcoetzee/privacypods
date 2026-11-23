import Carbon.HIToolbox
import Foundation

/// Owner tag read back from the event; global because a `@convention(c)` callback cannot capture.
private let reanchorSignature: OSType = 0x5050_6F64  // 'PPod'

/// Carbon `RegisterEventHotKey` needs no Input Monitoring, which is why it is used over `NSEvent`.
@MainActor
final class ReanchorHotkeyMonitor {
    let events: AsyncStream<Date>

    private let continuation: AsyncStream<Date>.Continuation
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    deinit {
        continuation.finish()
    }

    /// Returns `false` when the combination is taken; callers must surface it, as this is the only
    /// anchoring route when Input Monitoring is denied.
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var fired = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &fired
                )
                guard read == noErr, fired.signature == reanchorSignature else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<ReanchorHotkeyMonitor>.fromOpaque(context).takeUnretainedValue().fire()
                }
                return noErr
            }, 1, &spec, context, &handler)

        guard installed == noErr else {
            Log.gaze.error("Could not install the re-anchor hotkey handler (\(installed))")
            return false
        }

        let id = EventHotKeyID(signature: reanchorSignature, id: 1)
        let registered = RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers.carbonFlags, id, GetApplicationEventTarget(), 0, &hotKey
        )
        guard registered == noErr else {
            Log.gaze.error("Could not register \(hotkey.modifiers.symbols, privacy: .public) as the re-anchor hotkey (\(registered))")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func fire() {
        continuation.yield(Date())
    }
}
