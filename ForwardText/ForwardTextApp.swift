import SwiftUI

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
