import SwiftUI

@main
struct ForwardTextApp: App {
    init() {
        // Auto-configure Gmail credentials on first launch
        let helper = ForwardMessageHelper.shared
        if helper.getKeychainValue(key: "refreshToken") == nil,
           !Secrets.gmailRefreshToken.isEmpty {
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
