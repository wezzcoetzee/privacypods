import Foundation
import Observation
import ServiceManagement

/// The persisted, observable copy of `AppSettings`. SwiftUI reads `settings` directly; anything
/// that changes the struct goes through this store so persistence and the launch-at-login side
/// effect happen exactly once, in one place.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            if settings.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin()
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Self.load(from: defaults)
        // The system is the source of truth for login items: the user can remove the app in
        // System Settings, or a registration can fail, and the stored flag would then lie.
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: AppSettings.defaultsKey) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.app.error("Discarding malformed settings, falling back to defaults: \(error, privacy: .public)")
            return AppSettings()
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: AppSettings.defaultsKey)
        } catch {
            Log.app.error("Failed to persist settings: \(error, privacy: .public)")
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
                // macOS can hold a new login item for approval; send the user to where they give it.
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Failed to update launch-at-login registration: \(error, privacy: .public)")
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
