import AppKit
import UserNotifications

/// The waiting reminder's notification: one per waiting session, taken back
/// when it stops waiting, and a click opens that session's card on the bar.
///
/// The only macOS permission Evlat asks for, and only when the user turns the
/// notification on (Settings → General → Waiting reminder); refused, the
/// sound still works. `UNUserNotificationCenter` needs a bundle: under
/// `swift run` and in tests there is none, and nothing here is built.
@MainActor
final class WaitingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    /// A click on a notification, with its session's entity.
    var onClick: (String) -> Void = { _ in }

    /// `nil` outside an app bundle or under XCTest.
    static func make() -> WaitingNotifier? {
        guard Bundle.main.bundleURL.pathExtension == "app", !WindowStage.isOffstage else { return nil }
        return WaitingNotifier(center: .current())
    }

    private init(center: UNUserNotificationCenter) {
        self.center = center
        super.init()
        center.delegate = self
    }

    private static let prefix = "evlat.waiting."

    /// Asks once; macOS remembers the answer. Called back on the main queue.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Whether the user has turned Evlat's notifications off in System Settings.
    func isDenied(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { completion(denied) }
        }
    }

    /// Silent: the chime is the sound, when it is chosen.
    func post(entity: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["entity": entity]
        center.add(UNNotificationRequest(identifier: Self.prefix + entity, content: content, trigger: nil))
    }

    func remove(entities: Set<String>) {
        guard !entities.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: entities.map { Self.prefix + $0 })
    }

    // Evlat always counts as the front app for the system (an accessory app
    // with a panel), so without this the banner would never show.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let entity = response.notification.request.content.userInfo["entity"] as? String
        DispatchQueue.main.async { [weak self] in
            if let entity { self?.onClick(entity) }
            completionHandler()
        }
    }
}
