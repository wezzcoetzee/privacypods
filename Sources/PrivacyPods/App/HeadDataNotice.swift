import UserNotifications

enum HeadDataNotice {
    static func reasonToPost(
        from old: WearState, to new: WearState, settings: AppSettings, alreadyPosted: Bool
    ) -> WearState.Reason? {
        guard !alreadyPosted, old.isWorn, case .unknown(let reason) = new, reason != .permissionDenied,
            settings.isEnabled, settings.blurMode != .off, settings.failModeChosen, settings.failMode == .open
        else { return nil }
        return reason
    }

    static func post(_ reason: WearState.Reason) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = reason.title
            content.body = body(for: reason)
            try? await center.add(UNNotificationRequest(identifier: "head-data-stopped", content: content, trigger: nil))
        }
    }

    private static func body(for reason: WearState.Reason) -> String {
        let fix =
            reason == .motionUnavailable
            ? "Restart head tracking in the Status window"
            : "Put your AirPods back in"
        return "Your screens are readable. \(fix), or choose Blur for this in Settings."
    }
}
