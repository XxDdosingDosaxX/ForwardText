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

        // Request notification permission for queue alerts and auth failures
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        // Proactively validate the token on launch to catch expired tokens early
        helper.validateTokenOnLaunch { success, error in
            if !success {
                MessageQueue.shared.logEvent(.tokenRefreshFailed, detail: "Launch validation failed: \(error ?? "unknown")")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
