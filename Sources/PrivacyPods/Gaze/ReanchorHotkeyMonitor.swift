import Carbon.HIToolbox
import Foundation

/// `RegisterEventHotKey`'s four-character owner tag, read back from the event so this monitor
/// ignores hotkeys registered by anyone else. A `@convention(c)` callback can capture nothing,
/// so it has to live out here.
private let reanchorSignature: OSType = 0x5050_6F64 // 'PPod'

/// The global re-anchor hotkey.
///
/// Carbon rather than an `NSEvent` monitor on purpose: `RegisterEventHotKey` needs no Input
/// Monitoring permission, and this hotkey is precisely the fallback for the case where that
/// permission is missing.
@MainActor
final class ReanchorHotkeyMonitor {
    /// Single-consumer, carrying the instant of each press.
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

    /// Registers `hotkey`, replacing whatever was registered before. Safe to call on every
    /// settings change.
    ///
    /// Returns `false` when the combination is unavailable, which is usually another app
    /// holding it. The re-anchor hotkey is the only anchoring route left when Input Monitoring
    /// is denied, so a silent failure there is a dead app; the caller has to say so, which is
    /// why the result is not discardable.
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
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
