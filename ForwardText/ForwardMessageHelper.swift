import Foundation
import UserNotifications

class ForwardMessageHelper {
    static let shared = ForwardMessageHelper()

    private let keychainService = "com.forwardtext.gmail"

    // Cached access token to avoid refreshing on every call
    private var cachedAccessToken: String?
    private var tokenExpiry: Date?

    // Track consecutive auth failures to detect permanent revocation
    private var consecutiveAuthFailures: Int = 0
    private static let maxAuthRetries: Int = 3

    /// Re-populate keychain from build-time Secrets if missing.
    /// This self-heals after iOS clears keychain (updates, storage pressure, etc.)
    func ensureCredentials() {
        if getKeychainValue(key: "refreshToken") == nil && !Secrets.gmailRefreshToken.isEmpty {
            setKeychainValue(key: "clientId", value: Secrets.gmailClientId)
            setKeychainValue(key: "clientSecret", value: Secrets.gmailClientSecret)
            setKeychainValue(key: "refreshToken", value: Secrets.gmailRefreshToken)
        }
    }

    /// Validate the current refresh token by attempting a token exchange.
    /// Call on app launch to detect revoked tokens early.
    func validateTokenOnLaunch(completion: @escaping (Bool, String?) -> Void) {
        ensureCredentials()
        guard let refreshToken = getKeychainValue(key: "refreshToken"),
              let clientId = getKeychainValue(key: "clientId"),
              let clientSecret = getKeychainValue(key: "clientSecret") else {
            completion(false, "No credentials stored")
            return
        }

        // Force a fresh token exchange (bypass cache)
        refreshAccessToken(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret) { token, error in
            if let _ = token {
                self.consecutiveAuthFailures = 0
                completion(true, nil)
            } else {
                completion(false, error)
            }
        }
    }

    // MARK: - Single Message (for test button in UI)

    func forward(message: String, sender: String, to email: String, completion: @escaping (Bool) -> Void) {
        let messages = [QueuedMessage(sender: sender, message: message)]
        forwardBatch(messages: messages, to: email) { success, _ in
            completion(success)
        }
    }

    // MARK: - Batch Send

    func forwardBatch(messages: [QueuedMessage], to email: String, completion: @escaping (Bool, String) -> Void) {
        ensureCredentials()
        guard let refreshToken = getKeychainValue(key: "refreshToken"),
              let clientId = getKeychainValue(key: "clientId"),
              let clientSecret = getKeychainValue(key: "clientSecret") else {
            let error = "Gmail credentials not found in Keychain"
            MessageQueue.shared.logEvent(.failed, detail: error)
            notifyAuthFailure(reason: "No Gmail credentials. Open the app to re-authenticate.")
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
            self.consecutiveAuthFailures = 0

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

            self.sendEmail(to: email, subject: subject, body: body, accessToken: token) { success, sendError in
                if success {
                    completion(true, "")
                } else if self.isAuthError(sendError) {
                    // Token might have been revoked between refresh and send — retry once with fresh token
                    MessageQueue.shared.logEvent(.retrying, detail: "Got 401 on send, retrying with fresh token")
                    self.cachedAccessToken = nil
                    self.tokenExpiry = nil

                    self.getValidAccessToken(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret) { retryToken, retryError in
                        guard let retryToken = retryToken else {
                            completion(false, retryError ?? "Retry token refresh failed")
                            return
                        }
                        self.sendEmail(to: email, subject: subject, body: body, accessToken: retryToken, completion: completion)
                    }
                } else {
                    completion(false, sendError)
                }
            }
        }
    }

    // MARK: - Token Management

    private func getValidAccessToken(refreshToken: String, clientId: String, clientSecret: String, completion: @escaping (String?, String?) -> Void) {
        // Use cached token if still valid (with 5-minute buffer for safety)
        if let cached = cachedAccessToken, let expiry = tokenExpiry, Date() < expiry.addingTimeInterval(-300) {
            completion(cached, nil)
            return
        }

        refreshAccessToken(refreshToken: refreshToken, clientId: clientId, clientSecret: clientSecret, completion: completion)
    }

    /// Perform the actual OAuth token refresh against Google's endpoint.
    private func refreshAccessToken(refreshToken: String, clientId: String, clientSecret: String, completion: @escaping (String?, String?) -> Void) {
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
                self.consecutiveAuthFailures = 0

                // If Google returns a new refresh token (rare but possible), save it
                if let newRefreshToken = json["refresh_token"] as? String, !newRefreshToken.isEmpty {
                    self.setKeychainValue(key: "refreshToken", value: newRefreshToken)
                    MessageQueue.shared.logEvent(.tokenRefreshSuccess, detail: "Saved new refresh token from Google")
                }

                completion(accessToken, nil)
            } else if let errorCode = json["error"] as? String {
                let errorDesc = json["error_description"] as? String ?? "No description"
                let fullError = "OAuth error: \(errorCode) — \(errorDesc)"

                self.consecutiveAuthFailures += 1

                if errorCode == "invalid_grant" {
                    // Refresh token is permanently revoked or expired (7-day testing mode limit)
                    // Clear stale credentials so ensureCredentials() can re-populate from Secrets
                    self.cachedAccessToken = nil
                    self.tokenExpiry = nil
                    self.deleteKeychainValue(key: "refreshToken")

                    // Try re-populating from Secrets (in case they were updated in a new build)
                    if !Secrets.gmailRefreshToken.isEmpty {
                        self.setKeychainValue(key: "refreshToken", value: Secrets.gmailRefreshToken)

                        // Retry once with the Secrets token (it might be a fresh one from a new build)
                        if self.consecutiveAuthFailures <= Self.maxAuthRetries {
                            MessageQueue.shared.logEvent(.retrying, detail: "invalid_grant — retrying with Secrets token (attempt \(self.consecutiveAuthFailures))")
                            self.refreshAccessToken(
                                refreshToken: Secrets.gmailRefreshToken,
                                clientId: clientId,
                                clientSecret: clientSecret,
                                completion: completion
                            )
                            return
                        }
                    }

                    // Permanent failure — notify user
                    self.notifyAuthFailure(reason: "Gmail refresh token expired or revoked. Open Forward Text app and tap 'Re-authenticate Gmail' to fix.")
                    MessageQueue.shared.logEvent(.tokenRefreshFailed, detail: "PERMANENT: \(fullError). User must re-authenticate.")
                    completion(nil, fullError)
                } else {
                    completion(nil, fullError)
                }
            } else {
                completion(nil, "Token response missing access_token (HTTP \(httpStatus)): \(json)")
            }
        }.resume()
    }

    /// Check if an error string indicates an authentication/authorization failure
    private func isAuthError(_ error: String) -> Bool {
        return error.contains("HTTP 401") || error.contains("HTTP 403") || error.contains("invalid_grant")
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

    // MARK: - Notifications

    /// Send a local notification alerting the user to a permanent auth failure
    private func notifyAuthFailure(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Forward Text: Gmail Auth Failed"
        content.body = reason
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "auth-failure-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - OAuth Re-authentication Flow

    /// Store new OAuth tokens obtained from an in-app re-authentication flow.
    /// This is the permanent fix for expired/revoked refresh tokens.
    func saveNewTokens(accessToken: String, refreshToken: String, expiresIn: Int = 3600) {
        setKeychainValue(key: "refreshToken", value: refreshToken)
        cachedAccessToken = accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        consecutiveAuthFailures = 0
        MessageQueue.shared.logEvent(.tokenRefreshSuccess, detail: "New tokens saved from re-authentication")
    }

    /// Exchange an authorization code for tokens (used by the in-app OAuth flow).
    func exchangeCodeForTokens(code: String, redirectURI: String, completion: @escaping (Bool, String?) -> Void) {
        guard let clientId = getKeychainValue(key: "clientId") ?? (Secrets.gmailClientId.isEmpty ? nil : Secrets.gmailClientId),
              let clientSecret = getKeychainValue(key: "clientSecret") ?? (Secrets.gmailClientSecret.isEmpty ? nil : Secrets.gmailClientSecret) else {
            completion(false, "No client ID/secret available")
            return
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&client_secret=\(clientSecret)&code=\(code)&grant_type=authorization_code&redirect_uri=\(redirectURI)"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "Network error: \(error.localizedDescription)")
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, "Invalid response from token endpoint")
                return
            }

            if let accessToken = json["access_token"] as? String,
               let refreshToken = json["refresh_token"] as? String {
                let expiresIn = json["expires_in"] as? Int ?? 3600
                self.saveNewTokens(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn)
                // Also save client credentials in keychain
                self.setKeychainValue(key: "clientId", value: clientId)
                self.setKeychainValue(key: "clientSecret", value: clientSecret)
                completion(true, nil)
            } else {
                let errorDesc = json["error_description"] as? String ?? json["error"] as? String ?? "Unknown error"
                completion(false, "Token exchange failed: \(errorDesc)")
            }
        }.resume()
    }

    /// Build the Google OAuth authorization URL for the in-app re-auth flow.
    func buildAuthURL(redirectURI: String) -> URL? {
        let clientId = getKeychainValue(key: "clientId") ?? Secrets.gmailClientId
        guard !clientId.isEmpty else { return nil }

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"), // Force consent to always get a refresh token
        ]
        return components.url
    }

    // MARK: - Keychain

    func setKeychainValue(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        // Add with proper accessibility for background execution
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            MessageQueue.shared.logEvent(.failed, detail: "Keychain write failed for \(key): OSStatus \(status)")
        }
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

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            // Log non-trivial errors (not just "not found")
            MessageQueue.shared.logEvent(.failed, detail: "Keychain read failed for \(key): OSStatus \(status)")
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    func deleteKeychainValue(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Check whether we currently have a valid (non-expired) refresh token.
    var hasValidCredentials: Bool {
        return getKeychainValue(key: "refreshToken") != nil
    }

    /// Whether the last auth attempt failed permanently (token revoked/expired)
    var isAuthPermanentlyFailed: Bool {
        return consecutiveAuthFailures >= Self.maxAuthRetries
    }

    // MARK: - Helpers

    static func formattedDate(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
