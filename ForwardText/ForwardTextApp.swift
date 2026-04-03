import SwiftUI
import UserNotifications

@main
struct ForwardTextApp: App {
    init() {
        // Auto-configure Gmail credentials from build-time secrets
        let helper = ForwardMessageHelper.shared
        if !Secrets.gmailRefreshToken.isEmpty {
            helper.setKeychainValue(key: "clientId", value: Secrets.gmailClientId)
            helper.setKeychainValue(key: "clientSecret", value: Secrets.gmailClientSecret)
            helper.setKeychainValue(key: "refreshToken", value: Secrets.gmailRefreshToken)
        }

        // Request notification permission for queue alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
