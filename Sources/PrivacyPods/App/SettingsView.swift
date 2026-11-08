import SwiftUI

/// Settings: what blurs, what happens when you leave, and the tracking that decides both.
/// Pausing is not here; it is something you do, not something you set, and it lives in the menu.
struct SettingsView: View {
    /// Read for one thing: whether the shortcut chosen below actually registered.
    let coordinator: AppCoordinator
    @Bindable var settings: SettingsStore

    /// The delays of "Blur, then lock", kept while another response is selected so switching
    /// back does not throw the user's numbers away.
    @State private var timings = AwayTimings()

    var body: some View {
        Pane(width: 480) {
            PaneSection(title: "Blur") {
                LabeledContent("Mode") {
                    Picker("Mode", selection: $settings.settings.blurMode) {
                        ForEach(BlurMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help("When you look away: every display blurs while you are looking at none of them. Displays you're not looking at: every display except the one you are looking at stays blurred.")
                if settings.settings.blurMode == .off, settings.settings.awayPolicy != .doNothing {
                    Text("Walking away still blurs every display.")
                        .font(.callout)
                        .padding(.vertical, 7)
                }
                LabeledContent("If head data stops") {
                    Picker("If head data stops", selection: $settings.settings.failMode) {
                        ForEach(FailMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(settings.settings.blurMode == .off)
                }
                .help(settings.settings.blurMode == .off
                    ? "Blur is off, so there is nothing to cover."
                    : "What the screens do while the AirPods send no head data: out, in the case, or taken by your iPhone. This never locks the Mac.")

                LabeledContent("Strength") {
                    Text("Light").accessibilityHidden(true)
                    Slider(value: $settings.settings.blurRadius, in: Self.strengthRange) { Text("Strength") }
                        .labelsHidden()
                        .frame(width: 140)
                        .accessibilityValue("\(strengthPercent) percent")
                    Text("Heavy").accessibilityHidden(true)
                }
            }

            PaneSection(title: "When you walk away") {
                LabeledContent("Response") {
                    Picker("Response", selection: awayPolicyKind) {
                        Text("Do nothing").tag(AwayPolicyKind.doNothing)
                        Text("Blur, then lock").tag(AwayPolicyKind.blurThenLock)
                        Text("Lock immediately").tag(AwayPolicyKind.lockImmediately)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if case .blurThenLock(let blurAfter, let lockAfter) = settings.settings.awayPolicy {
                    LabeledContent("Blur after") {
                        delayPicker("Blur after", \.blurAfter, choices: AwayTimings.presets(below: lockAfter, keeping: blurAfter))
                    }
                    LabeledContent("Lock after") {
                        delayPicker("Lock after", \.lockAfter, choices: AwayTimings.presets(above: blurAfter, keeping: lockAfter))
                    }
                }
                if settings.settings.awayPolicy != .doNothing {
                    Text(Issue.awayRule(canType: coordinator.canType) + (settings.settings.awayPolicy == .lockImmediately ? "" : " Delays count from then."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }

            PaneSection(title: "Tracking") {
                LabeledContent("Horizontal range") {
                    presetPicker("Horizontal range", degrees(\.yawHalfAngle), presets: Self.rangePresets) { "±\(Int($0))°" }
                }
                .help("How far you can turn your head from a display and still count as looking at it.")
                LabeledContent("Vertical range") {
                    presetPicker("Vertical range", degrees(\.pitchHalfAngle), presets: Self.rangePresets) { "±\(Int($0))°" }
                }
                .help("How far you can tilt your head from a display and still count as looking at it.")
                LabeledContent("Look-away delay") {
                    presetPicker("Look-away delay", $settings.settings.awayGrace, presets: Self.gracePresets) {
                        $0 == 1 ? "1 second" : String(format: "%g seconds", $0)
                    }
                }
                .help("How long a glance away lasts before it counts. Looking back is immediate.")
                LabeledContent("Re-anchor shortcut") {
                    if settings.settings.reanchorHotkey != .reanchorDefault {
                        Button("Reset") { settings.settings.reanchorHotkey = .reanchorDefault }
                    }
                    HotkeyRecorder(hotkey: $settings.settings.reanchorHotkey)
                }
                .help("Anchors the display under the pointer to where your head is now.")
                if !coordinator.isReanchorHotkeyAvailable {
                    PaneNotice(text: Issue.hotkeyTakenText(settings.settings.reanchorHotkey.label) + " Record a different one.")
                }
            }

            PaneSection(title: "General") {
                LabeledContent("Launch at login") {
                    Toggle("Launch at login", isOn: $settings.settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                LoginItemApprovalNotice(isOn: settings.settings.launchAtLogin)
            }
        }
        .onAppear {
            if case .blurThenLock(let blurAfter, let lockAfter) = settings.settings.awayPolicy {
                timings = AwayTimings(blurAfter: blurAfter, lockAfter: lockAfter)
            }
        }
    }

    private static let strengthRange: ClosedRange<Double> = 20...120
    private static let rangePresets: [Double] = [10, 15, 20, 25, 30, 35, 40, 45]
    private static let gracePresets: [Double] = [0.3, 0.5, 0.7, 1, 1.5, 2, 3]

    private var strengthPercent: Int {
        Int(((settings.settings.blurRadius - Self.strengthRange.lowerBound)
            / (Self.strengthRange.upperBound - Self.strengthRange.lowerBound) * 100).rounded())
    }

    /// A pop-up of sensible values, as for the walk-away delays, plus the current value if it is
    /// a custom one carried over from an older build.
    private func presetPicker(
        _ label: String, _ binding: Binding<Double>, presets: [Double], format: @escaping (Double) -> String
    ) -> some View {
        Picker(label, selection: binding) {
            ForEach(Set(presets + [binding.wrappedValue]).sorted(), id: \.self) { Text(format($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func delayPicker(
        _ label: String, _ field: WritableKeyPath<AwayTimings, TimeInterval>, choices: [TimeInterval]
    ) -> some View {
        Picker(label, selection: Binding(
            get: { timings[keyPath: field] },
            set: {
                timings[keyPath: field] = $0
                settings.settings.awayPolicy = .blurThenLock(blurAfter: timings.blurAfter, lockAfter: timings.lockAfter)
            }
        )) {
            ForEach(choices, id: \.self) { Text(AwayTimings.label($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private enum AwayPolicyKind: Hashable {
        case doNothing, blurThenLock, lockImmediately
    }

    private var awayPolicyKind: Binding<AwayPolicyKind> {
        Binding(
            get: {
                switch settings.settings.awayPolicy {
                case .doNothing: .doNothing
                case .blurThenLock: .blurThenLock
                case .lockImmediately: .lockImmediately
                }
            },
            set: { kind in
                settings.settings.awayPolicy = switch kind {
                case .doNothing: .doNothing
                case .blurThenLock: .blurThenLock(blurAfter: timings.blurAfter, lockAfter: timings.lockAfter)
                case .lockImmediately: .lockImmediately
                }
            }
        )
    }

    private func degrees(_ field: WritableKeyPath<AcceptanceCone, Degrees>) -> Binding<Double> {
        Binding(
            get: { settings.settings.acceptanceCone[keyPath: field].value },
            set: { settings.settings.acceptanceCone[keyPath: field] = Degrees($0) }
        )
    }
}

/// The two delays of "Blur, then lock", offered as presets in the way macOS offers its own
/// "require password after" delays, rather than as a stepper that takes hundreds of clicks.
struct AwayTimings: Hashable {
    var blurAfter: TimeInterval = 5
    var lockAfter: TimeInterval = 30

    private static let presets: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600]

    /// Presets strictly below `limit`, plus `current` if it is a custom value from an older build.
    static func presets(below limit: TimeInterval, keeping current: TimeInterval) -> [TimeInterval] {
        Set(presets.filter { $0 < limit } + [current]).sorted()
    }

    static func presets(above limit: TimeInterval, keeping current: TimeInterval) -> [TimeInterval] {
        Set(presets.filter { $0 > limit } + [current]).sorted()
    }

    static func label(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(Int(seconds)) seconds"
    }
}
