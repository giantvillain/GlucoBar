import Foundation
import UserNotifications
import Combine

nonisolated final class AlertSchedule {
    private let defaults: UserDefaults
    private let key: String
    init(profile: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "GlucoBar.alerts." + profile
    }
    func allows(kind: String, cooldown: TimeInterval, now: Date, snoozedUntil: Date?) -> Bool {
        if let snoozedUntil, snoozedUntil > now { return false }
        let previous = defaults.dictionary(forKey: key)?[kind] as? Double
        return previous.map { now.timeIntervalSince1970 >= $0 + cooldown } ?? true
    }
    func record(kind: String, now: Date) {
        var values = defaults.dictionary(forKey: key) ?? [:]
        values[kind] = now.timeIntervalSince1970
        defaults.set(values, forKey: key)
    }
}

@MainActor
final class ForecastNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    struct Event {
        let status: GlucoseRangeStatus
        let minutes: Int
        let thresholdText: String
        let currentText: String
        let unitLabel: String
    }
    @Published private(set) var permissionText = "Checking permission…"
    @Published private(set) var authorized = false
    @Published private(set) var lastError: String?
    @Published private(set) var snoozedUntil: Date?
    private var profile: String?
    private var schedule = AlertSchedule(profile: "unconnected")
    private var sending: Set<String> = []
    private var generation = UUID()
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    override init() {
        snoozedUntil = (UserDefaults.standard.object(forKey: "GlucoBar.alertSnoozeUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        super.init()
        center?.delegate = self
    }

    func selectProfile(_ id: String?) {
        profile = id
        generation = UUID()
        sending = []
        schedule = AlertSchedule(profile: id ?? "unconnected")
        center?.removeDeliveredNotifications(withIdentifiers: ["glucobar.low", "glucobar.high", "glucobar.missing"])
    }

    func hideDeliveredReadings() {
        generation = UUID()
        sending = []
        center?.removePendingNotificationRequests(withIdentifiers: ["glucobar.low", "glucobar.high"])
        center?.removeDeliveredNotifications(withIdentifiers: ["glucobar.low", "glucobar.high"])
    }

    func refreshAuthorization() async {
        guard let center else { permissionText = "Unavailable outside the app"; return }
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        switch settings.authorizationStatus {
        case .authorized, .provisional: permissionText = settings.alertSetting == .enabled ? "Notifications allowed" : "Allowed, but banners are off in macOS"
        case .denied: permissionText = "Blocked in macOS Notification settings"
        case .notDetermined: permissionText = "Permission has not been requested"
        default: permissionText = "Notifications unavailable"
        }
    }

    func requestAuthorizationIfNeeded() {
        Task {
            guard let center else { return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { lastError = error.localizedDescription }
            await refreshAuthorization()
        }
    }

    func snooze(minutes: Int) {
        snoozedUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        UserDefaults.standard.set(snoozedUntil?.timeIntervalSince1970, forKey: "GlucoBar.alertSnoozeUntil")
    }

    func evaluate(event: Event?, notifyLow: Bool, notifyHigh: Bool, cooldown: TimeInterval, privacy: Bool) {
        guard let event else { return }
        let wanted = (event.status == .low && notifyLow) || (event.status == .high && notifyHigh)
        guard wanted else { return }
        let direction = event.status == .low ? "fall below" : "rise above"
        send(kind: event.status == .low ? "low" : "high",
             title: privacy ? "GlucoBar forecast update" : (event.status == .low ? "Low glucose predicted" : "High glucose predicted"),
             body: privacy ? "Open GlucoBar to view the forecast." : "May \(direction) \(event.thresholdText) \(event.unitLabel) in about \(event.minutes) min. Now \(event.currentText).",
             cooldown: cooldown)
    }

    func missingData(lastReading: Date, cooldown: TimeInterval) {
        send(kind: "missing", title: "Glucose readings delayed",
             body: "No new reading since \(lastReading.formatted(date: .omitted, time: .shortened)). Open GlucoBar to check the connection.",
             cooldown: cooldown)
    }

    func testNotification() {
        send(kind: "test", title: "GlucoBar test notification", body: "Notifications are working. This is a test, not a glucose alert.", cooldown: 0, test: true)
    }

    private func send(kind: String, title: String, body: String, cooldown: TimeInterval, test: Bool = false) {
        guard (test || profile != nil), !sending.contains(kind),
              test || schedule.allows(kind: kind, cooldown: cooldown, now: .now, snoozedUntil: snoozedUntil) else { return }
        sending.insert(kind)
        let token = generation
        Task {
            defer { if token == generation { sending.remove(kind) } }
            await refreshAuthorization()
            guard token == generation, authorized, let center,
                  test || schedule.allows(kind: kind, cooldown: cooldown, now: .now, snoozedUntil: snoozedUntil) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "glucobar.\(kind)", content: content, trigger: nil))
                guard token == generation else { return }
                if !test { schedule.record(kind: kind, now: .now) }
                lastError = nil
            } catch { lastError = error.localizedDescription }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
