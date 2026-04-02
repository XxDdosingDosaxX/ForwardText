import Foundation

/// Handles forwarding messages to email via a simple HTTPS webhook or SMTP relay.
/// Uses a free email sending service (EmailJS or a simple Cloudflare Worker).
/// For simplicity, we'll use a direct Gmail API approach via a pre-authenticated token,
/// or fall back to a mailto: URL scheme.
///
/// The simplest approach that works without a server: use MFMailComposeViewController
/// in the background isn't possible (requires UI). Instead, we'll use a lightweight
/// HTTP endpoint or the Gmail SMTP directly.
///
/// APPROACH: Use a simple HTTPS POST to a free webhook service (like Make.com/Zapier free tier)
/// OR use the Gmail API directly with a stored refresh token.
///
/// For THIS app, we'll use the Gmail API with OAuth tokens stored in Keychain.
class ForwardMessageHelper {
    static let shared = ForwardMessageHelper()

    private let keychainService = "com.forwardtext.gmail"

    func forward(message: String, sender: String, to email: String, completion: @escaping (Bool) -> Void) {
        // Try Gmail API first, fall back to webhook
        if let refreshToken = getKeychainValue(key: "refreshToken"),
           let clientId = getKeychainValue(key: "clientId"),
           let clientSecret = getKeychainValue(key: "clientSecret") {
            sendViaGmailAPI(
                message: message,
                sender: sender,
                to: email,
                refreshToken: refreshToken,
                clientId: clientId,
                clientSecret: clientSecret,
                completion: completion
            )
        } else {
            // Fallback: use a simple webhook POST
            sendViaWebhook(message: message, sender: sender, to: email, completion: completion)
        }
    }

    // MARK: - Gmail API Method

    private func sendViaGmailAPI(
        message: String,
        sender: String,
        to email: String,
        refreshToken: String,
        clientId: String,
        clientSecret: String,
        completion: @escaping (Bool) -> Void
    ) {
        // Step 1: Refresh the access token
        refreshAccessToken(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret) { accessToken in
            guard let token = accessToken else {
                completion(false)
                return
            }

            // Step 2: Send the email
            let timestamp = Self.formattedDate()
            let subject = "Forwarded Text from \(sender) — \(timestamp)"
            let body = """
            From: \(sender)
            Time: \(timestamp)

            \(message)

            ---
            Forwarded by Forward Text app
            """

            let rawEmail = """
            From: \(email)
            To: \(email)
            Subject: \(subject)
            Content-Type: text/plain; charset=utf-8

            \(body)
            """

            let base64Email = rawEmail.data(using: .utf8)!
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")

            // Use "insert" instead of "send" to avoid cluttering the Sent folder.
            // The message goes directly into the mailbox with the "Forwarded Texts" label.
            let labelId = "Label_5" // "Forwarded Texts" label
            let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/import?internalDateSource=dateHeader")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "raw": base64Email,
                "labelIds": [labelId]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            URLSession.shared.dataTask(with: request) { data, response, error in
                let httpResponse = response as? HTTPURLResponse
                let success = httpResponse?.statusCode == 200
                if !success {
                    // Log for debugging
                    if let data = data, let body = String(data: data, encoding: .utf8) {
                        print("ForwardText: Gmail import failed: \(httpResponse?.statusCode ?? 0) - \(body)")
                    }
                }
                completion(success)
            }.resume()
        }
    }

    private func refreshAccessToken(
        refreshToken: String,
        clientId: String,
        clientSecret: String,
        completion: @escaping (String?) -> Void
    ) {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&client_secret=\(clientSecret)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                completion(nil)
                return
            }
            completion(accessToken)
        }.resume()
    }

    // MARK: - Webhook Fallback

    private func sendViaWebhook(message: String, sender: String, to email: String, completion: @escaping (Bool) -> Void) {
        // If no Gmail API credentials, try a webhook URL stored in UserDefaults
        guard let webhookURL = UserDefaults.standard.string(forKey: "webhookURL"),
              let url = URL(string: webhookURL) else {
            // Last resort: just log it
            print("ForwardText: No forwarding method configured. Message from \(sender): \(message)")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "message": message,
            "sender": sender,
            "email": email,
            "timestamp": Self.formattedDate()
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            completion(httpResponse?.statusCode == 200)
        }.resume()
    }

    // MARK: - Keychain

    func setKeychainValue(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary) // Remove old value
        SecItemAdd(query as CFDictionary, nil)
    }

    func getKeychainValue(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: Date())
    }
}
