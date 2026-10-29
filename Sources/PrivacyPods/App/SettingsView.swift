import SwiftUI

/// Dark, information-dense settings. No decorative chrome, no subtitle lines above sections.
struct SettingsView: View {
    /// Read for one thing: whether the combination chosen below actually registered.
    let coordinator: AppCoordinator
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Blur") {
                Picker("Mode", selection: $settings.settings.blurMode) {
                    ForEach(BlurMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("During sensor gaps", selection: $settings.settings.failMode) {
                    ForEach(FailMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                LabeledContent("Radius") {
                    Slider(value: $settings.settings.blurRadius, in: 20...120, step: 5) {
                        Text("Radius")
                    }
                    Text("\(Int(settings.settings.blurRadius)) pt").monospacedDigit()
                }
            }

            Section("Gaze") {
                LabeledContent("Yaw cone") {
                    Stepper(
                        "\(Int(settings.settings.acceptanceCone.yawHalfAngle.value))°",
                        value: Binding(
                            get: { settings.settings.acceptanceCone.yawHalfAngle.value },
                            set: { settings.settings.acceptanceCone.yawHalfAngle = Degrees($0) }
                        ),
                        in: 5...60
                    )
                }
                LabeledContent("Pitch cone") {
                    Stepper(
                        "\(Int(settings.settings.acceptanceCone.pitchHalfAngle.value))°",
                        value: Binding(
                            get: { settings.settings.acceptanceCone.pitchHalfAngle.value },
                            set: { settings.settings.acceptanceCone.pitchHalfAngle = Degrees($0) }
                        ),
                        in: 5...60
                    )
                }
                LabeledContent("Away grace") {
                    Stepper(
                        String(format: "%.1f s", settings.settings.awayGrace),
                        value: $settings.settings.awayGrace,
                        in: 0.1...3,
                        step: 0.1
                    )
                }
                LabeledContent("Re-anchor hotkey") {
                    HotkeyRecorder(hotkey: $settings.settings.reanchorHotkey)
                }
                if !coordinator.isReanchorHotkeyAvailable {
                    Label("Another app already holds this combination", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Away policy") {
                Picker("Policy", selection: awayPolicyKind) {
                    Text("Do nothing").tag(AwayPolicyKind.doNothing)
                    Text("Blur then lock").tag(AwayPolicyKind.blurThenLock)
                    Text("Lock immediately").tag(AwayPolicyKind.lockImmediately)
                }
                if case .blurThenLock(let blurAfter, let lockAfter) = settings.settings.awayPolicy {
                    LabeledContent("Blur after") {
                        Stepper(
                            "\(Int(blurAfter)) s",
                            value: Binding(
                                get: { blurAfter },
                                set: { settings.settings.awayPolicy = .blurThenLock(blurAfter: $0, lockAfter: lockAfter) }
                            ),
                            in: 1...120
                        )
                    }
                    LabeledContent("Lock after") {
                        Stepper(
                            "\(Int(lockAfter)) s",
                            value: Binding(
                                get: { lockAfter },
                                set: { settings.settings.awayPolicy = .blurThenLock(blurAfter: blurAfter, lockAfter: $0) }
                            ),
                            in: 1...600
                        )
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $settings.settings.launchAtLogin)
                Toggle("Enabled", isOn: $settings.settings.isEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 400)
        .preferredColorScheme(.dark)
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
                case .blurThenLock: .blurThenLock(blurAfter: 5, lockAfter: 30)
                case .lockImmediately: .lockImmediately
                }
            }
        )
    }
}
