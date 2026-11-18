import UserNotifications

/// Tells the owner when protection quietly stops: the AirPods go quiet (taken out, in the case,
/// or claimed by an iPhone) and "If head data stops" leaves the screens readable. The menu bar
/// icon changes too, but someone working in public is exactly the person who is not watching it.
///
/// Once per launch, and asked for the first time it would be shown rather than on first run: a
/// fifth permission prompt before the app has done anything would be one too many.
enum HeadDataNotice {
    /// The reason to post about, or `nil`. Only a change from worn counts, so launching without
    /// AirPods says nothing, and a refused Motion is the Status window's to explain. Nothing
    /// before the owner has chosen Stay readable: during setup the Status window is asking.
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
