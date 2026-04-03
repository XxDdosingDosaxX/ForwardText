import Foundation

class ForwardMessageHelper {
    static let shared = ForwardMessageHelper()

    private let keychainService = "com.forwardtext.gmail"

    // Cached access token to avoid refreshing on every call
    private var cachedAccessToken: String?
    private var tokenExpiry: Date?

    // MARK: - Single Message (for test button in UI)

    func forward(message: String, sender: String, to email: String, completion: @escaping (Bool) -> Void) {
        let messages = [QueuedMessage(sender: sender, message: message)]
        forwardBatch(messages: messages, to: email) { success, _ in
            completion(success)
        }
    }

    // MARK: - Batch Send

    func forwardBatch(messages: [QueuedMessage], to email: String, completion: @escaping (Bool, String) -> Void) {
        guard let refreshToken = getKeychainValue(key: "refreshToken"),
              let clientId = getKeychainValue(key: "clientId"),
              let clientSecret = getKeychainValue(key: "clientSecret") else {
            let error = "Gmail credentials not found in Keychain"
            MessageQueue.shared.logEvent(.failed, detail: error)
            completion(false, error)
            return
        }

        getValidAccessToken(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret) { token, error in
            guard let token = token else {
                let errorMsg = error ?? "Unknown token error"
                MessageQueue.shared.logEvent(.tokenRefreshFailed, detail: errorMsg)
                completion(false, errorMsg)
                return
            }

            MessageQueue.shared.logEvent(.tokenRefreshSuccess, detail: "Token ready")

            // Build one email with all messages
            let subject: String
            let body: String

            if messages.count == 1 {
                let msg = messages[0]
                let timestamp = Self.formattedDate(msg.timestamp)
                subject = "Forwarded Text from \(msg.sender) \u{2014} \(timestamp)"
                body = """
                From: \(msg.sender)
                Time: \(timestamp)

                \(msg.message)

                ---
                Forwarded by Forward Text app
                """
            } else {
                subject = "Forwarded Texts (\(messages.count) messages) \u{2014} \(Self.formattedDate())"
                var parts: [String] = []
                for msg in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
                    let timestamp = Self.formattedDate(msg.timestamp)
                    parts.append("""
                    From: \(msg.sender)
                    Time: \(timestamp)

                    \(msg.message)
                    """)
                }
                body = parts.joined(separator: "\n\n---\n\n") + "\n\n---\nForwarded by Forward Text app"
            }

            self.sendEmail(to: email, subject: subject, body: body, accessToken: token, completion: completion)
        }
    }

    // MARK: - Token Management

    private func getValidAccessToken(refreshToken: String, clientId: String, clientSecret: String, completion: @escaping (String?, String?) -> Void) {
        // Use cached token if still valid (with 60s buffer)
        if let cached = cachedAccessToken, let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-60) {
            completion(cached, nil)
            return
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&client_secret=\(clientSecret)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, "Network error refreshing token: \(error.localizedDescription)")
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard let data = data else {
                completion(nil, "No data from token endpoint (HTTP \(httpStatus))")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let raw = String(data: data, encoding: .utf8) ?? "unreadable"
                completion(nil, "Invalid JSON from token endpoint (HTTP \(httpStatus)): \(raw.prefix(200))")
                return
            }

            if let accessToken = json["access_token"] as? String {
                // Cache token — Google tokens last 3600s by default
                let expiresIn = json["expires_in"] as? Int ?? 3600
                self.cachedAccessToken = accessToken
                self.tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
                completion(accessToken, nil)
            } else if let errorDesc = json["error_description"] as? String {
                completion(nil, "OAuth error: \(json["error"] ?? "unknown") — \(errorDesc)")
            } else {
                completion(nil, "Token response missing access_token (HTTP \(httpStatus)): \(json)")
            }
        }.resume()
    }

    // MARK: - Gmail API Send

    private func sendEmail(to email: String, subject: String, body: String, accessToken: String, completion: @escaping (Bool, String) -> Void) {
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

        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["raw": base64Email]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                let msg = "Network error sending email: \(error.localizedDescription)"
                MessageQueue.shared.logEvent(.networkError, detail: msg)
                completion(false, msg)
                return
            }

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            if httpStatus == 200,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let messageId = json["id"] as? String {
                // Remove from inbox and sent so it doesn't clutter
                self.archiveAndClean(messageId: messageId, accessToken: accessToken)
                MessageQueue.shared.logEvent(.sent, detail: "Email sent (HTTP 200)")
                completion(true, "")
            } else {
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                let msg = "Gmail API error (HTTP \(httpStatus)): \(responseBody.prefix(300))"
                MessageQueue.shared.logEvent(.failed, detail: msg)
                completion(false, msg)
            }
        }.resume()
    }

    /// Trash the forwarded message so it doesn't show in Sent or Inbox.
    /// Gmail doesn't allow removing the SENT label via API, so we trash instead.
    /// The morning digest finds them with includeSpamTrash, then permanently deletes after reading.
    private func archiveAndClean(messageId: String, accessToken: String) {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/trash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Fire and forget — don't block on this
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

        SecItemDelete(query as CFDictionary)
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

    static func formattedDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
