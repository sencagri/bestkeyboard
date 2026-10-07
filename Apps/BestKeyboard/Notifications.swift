import UIKit
import UserNotifications

/// Yerel bildirimler — "Hatırlatıcılar'a eklendi" gibi onaylar. Klavyeden
/// gelen iş uygulamada bitiyor ama kullanıcı o sırada sohbete dönmüş oluyor;
/// bildirim sonucu orada gösteriyor. Dokununca `url` açılıyor (Hatırlatıcılar).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Uygulama açılışında bir kez: dokunmalar buraya gelsin.
    func install() { UNUserNotificationCenter.current().delegate = self }

    /// İzin ilk kullanımda isteniyor; reddedildiyse sessizce geçiliyor.
    func post(title: String, body: String, url: URL?) async {
        let c = UNUserNotificationCenter.current()
        let settings = await c.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await c.requestAuthorization(options: [.alert, .sound])
        }
        guard await c.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }
        try? await c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Uygulama öndeyken de afiş görünsün.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    // Dokununca hedefi aç. **Ana iş parçacığında**: UIKit yanıtın tamamlanmasını
    // orada bekliyor; arka planda bitince uygulamayı durduruyordu.
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        _ = await URLOpener.open(url)
    }
}
