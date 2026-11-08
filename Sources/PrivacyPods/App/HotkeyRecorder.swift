import AppKit
import SwiftUI

/// Records a global hotkey: click it, press the combination, done.
///
/// AppKit has no control for this and SwiftUI cannot see key events sent to another view, so
/// the capture is an otherwise invisible `NSView` that takes first responder while recording
/// and reads `keyDown` directly.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey

    @State private var isRecording = false

    var body: some View {
        Button(isRecording ? "Press shortcut, or Esc" : hotkey.label) { isRecording = true }
            .background(KeyCapture(isRecording: $isRecording) { hotkey = $0 })
            .help("Click, then press a key with ⌃ or ⌥, plus ⇧ or ⌘ if you like. Esc cancels.")
            .accessibilityHint(isRecording ? "Press the new shortcut, or Escape to cancel" : "Records a new shortcut")
    }
}

extension Hotkey {
    /// Menu-style label, e.g. `⌃⌥⌘R`.
    var label: String { modifiers.symbols + Self.keyLabels[keyCode, default: "Key \(keyCode)"] }

    /// The character an `NSMenuItem` needs to show this hotkey, or `nil` for keys a menu cannot
    /// spell (function and arrow keys), which then simply go unshown.
    var keyEquivalent: String? {
        guard let key = Self.keyLabels[keyCode] else { return nil }
        if key == "Space" { return " " }
        return key.count == 1 && !"←→↓↑".contains(key) ? key.lowercased() : nil
    }

    /// Virtual key codes are a fixed hardware map, not a character set: the label is what the
    /// key is called, not what it types on the current layout.
    private static let keyLabels: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x35: "Escape", 0x27: "'", 0x29: ";",
        0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`", 0x21: "[", 0x1E: "]", 0x2A: "\\",
        0x18: "=", 0x1B: "-",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}

extension Hotkey.Modifiers {
    private static let eventFlagPairs: [(Hotkey.Modifiers, NSEvent.ModifierFlags)] = [
        (.command, .command), (.option, .option), (.control, .control), (.shift, .shift),
    ]

    var eventFlags: NSEvent.ModifierFlags {
        Self.eventFlagPairs.reduce(into: []) { flags, pair in
            if contains(pair.0) { flags.insert(pair.1) }
        }
    }

    init(_ flags: NSEvent.ModifierFlags) {
        self = Self.eventFlagPairs.reduce(into: []) { modifiers, pair in
            if flags.contains(pair.1) { modifiers.insert(pair.0) }
        }
    }
}

private struct KeyCapture: NSViewRepresentable {
    @Binding var isRecording: Bool
    let captured: (Hotkey) -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.finished = { hotkey in
            if let hotkey { captured(hotkey) }
            isRecording = false
        }
        guard let window = view.window else { return }
        if isRecording {
            window.makeFirstResponder(view)
        } else if window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
    }
}

/// Invisible while idle; while it holds first responder it swallows one key combination.
private final class CaptureView: NSView {
    /// `nil` means the user cancelled, with Escape or by clicking elsewhere.
    var finished: ((Hotkey?) -> Void)?

    /// `kVK_Escape`, spelled out rather than dragging Carbon into this module for one constant.
    private static let escapeKeyCode: UInt16 = 0x35

    override var acceptsFirstResponder: Bool { true }

    /// A combination containing ⌘ is offered as a key equivalent before it is ever delivered as
    /// a key press, so without this the window's own controls would eat half the hotkeys a user
    /// might want to record.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = Hotkey.Modifiers(event.modifierFlags)
        guard event.keyCode != Self.escapeKeyCode else {
            finished?(nil)
            return
        }
        // A global hotkey takes its key away from every other app on the Mac. Without ⌃ or ⌥ it
        // would be a plain letter, a capital, or a standard ⌘ command like ⌘C. Keep listening
        // rather than cancelling, so a stray keypress does not lose the user's place.
        guard !modifiers.isDisjoint(with: [.control, .option]) else {
            NSSound.beep()
            return
        }
        finished?(Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    override func resignFirstResponder() -> Bool {
        let finished = finished
        Task { @MainActor in finished?(nil) }
        return true
    }
}
