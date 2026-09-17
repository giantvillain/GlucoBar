import Foundation
import UserNotifications

/// Posts a macOS notification when the forecast expects glucose to leave the target range.
final class ForecastNotifier: NSObject, UNUserNotificationCenterDelegate {
    struct Event {
        let status: GlucoseRangeStatus
        let minutes: Int
        let thresholdText: String
        let currentText: String
        let unitLabel: String
    }

    private var lastSent: [String: Date] = [:]
    private var authorizationRequested = false

    /// The notification centre is only usable from a real app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested, let center else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sends at most one notification per kind per cooldown period while a crossing is predicted.
    func evaluate(event: Event?, notifyLow: Bool, notifyHigh: Bool, cooldown: TimeInterval) {
        guard let event else { return }
        let wanted = (event.status == .low && notifyLow) || (event.status == .high && notifyHigh)
        guard wanted, let center else { return }

        let key = event.status == .low ? "low" : "high"
        let now = Date()
        if let previous = lastSent[key], now.timeIntervalSince(previous) < cooldown {
            return
        }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = event.status == .low ? "Low glucose predicted" : "High glucose predicted"
        let direction = event.status == .low ? "fall below" : "rise above"
        content.body = "May \(direction) \(event.thresholdText) \(event.unitLabel) in about \(event.minutes) min. Now \(event.currentText)."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "glucobar.forecast.\(key)", content: content, trigger: nil)
        center.add(request)
        lastSent[key] = now
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
