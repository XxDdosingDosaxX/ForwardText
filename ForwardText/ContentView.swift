import SwiftUI
import AuthenticationServices

struct ContentView: View {
    @AppStorage("forwardEmail") private var forwardEmail: String = ""
    @AppStorage("isSetup") private var isSetup: Bool = false
    @State private var showingSetupGuide = false
    @State private var showingLogs = false
    @State private var testStatus: String = ""
    @State private var queueCount: Int = 0
    @State private var lastForwarded: String = "Never"
    @State private var isReauthenticating = false
    @State private var authStatus: AuthStatus = .unknown
    @State private var showingReauth = false

    enum AuthStatus {
        case unknown, valid, expired, checking
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "message.badge.filled.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                    Text("Forward Text")
                        .font(.largeTitle.bold())
                    Text("Auto-forward texts to your email")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Email config
                VStack(alignment: .leading, spacing: 8) {
                    Text("Forward to email:")
                        .font(.headline)
                    TextField("your@email.com", text: $forwardEmail)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textContentType(.emailAddress)
                }
                .padding(.horizontal)

                // Status
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: forwardEmail.contains("@") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(forwardEmail.contains("@") ? .green : .red)
                        Text(forwardEmail.contains("@") ? "Email configured" : "Enter your email above")
                    }

                    HStack {
                        switch authStatus {
                        case .checking:
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Checking Gmail connection...")
                                .foregroundStyle(.secondary)
                        case .valid:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Gmail connected & token valid")
                        case .expired:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Gmail token expired")
                                .foregroundStyle(.red)
                        case .unknown:
                            let hasGmail = ForwardMessageHelper.shared.getKeychainValue(key: "refreshToken") != nil
                            Image(systemName: hasGmail ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(hasGmail ? .green : .red)
                            Text(hasGmail ? "Gmail connected" : "Gmail not connected")
                        }
                    }

                    // Show re-auth button when token is expired
                    if authStatus == .expired {
                        Button(action: { showingReauth = true }) {
                            Label("Re-authenticate Gmail", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .cornerRadius(8)
                        }
                    }

                    HStack {
                        Image(systemName: isSetup ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isSetup ? .green : .orange)
                        Text(isSetup ? "Shortcuts automation active" : "Set up Shortcuts automation")
                    }

                    Divider()

                    // Queue status
                    HStack {
                        Image(systemName: queueCount > 0 ? "tray.full.fill" : "tray.fill")
                            .foregroundStyle(queueCount > 0 ? .orange : .green)
                        Text(queueCount > 0 ? "\(queueCount) messages pending" : "Queue empty")
                    }

                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                        Text("Last sent: \(lastForwarded)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                // Buttons
                VStack(spacing: 12) {
                    Button(action: { showingSetupGuide = true }) {
                        Label("Setup Shortcuts Automation", systemImage: "gear")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    Button(action: sendTestMessage) {
                        Label("Send Test Email", systemImage: "paperplane")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    HStack(spacing: 12) {
                        Button(action: { showingReauth = true }) {
                            Label("Re-auth Gmail", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }

                        Button(action: { showingLogs = true }) {
                            Label("Logs", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(testStatus.contains("sent") ? .green : .secondary)
                        .padding(.horizontal)
                }

                Spacer()

                Text("Messages are forwarded directly from your device.\nNo data passes through external servers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
            }
            .navigationTitle("")
            .onAppear {
                refreshStatus()
                validateToken()
                flushQueueIfNeeded()
            }
            .sheet(isPresented: $showingSetupGuide) {
                SetupGuideView(isSetup: $isSetup)
            }
            .sheet(isPresented: $showingLogs) {
                LogsView()
            }
            .sheet(isPresented: $showingReauth) {
                OAuthReauthView(authStatus: $authStatus)
            }
        }
    }

    func validateToken() {
        authStatus = .checking
        ForwardMessageHelper.shared.validateTokenOnLaunch { success, error in
            DispatchQueue.main.async {
                authStatus = success ? .valid : .expired
            }
        }
    }

    func refreshStatus() {
        queueCount = MessageQueue.shared.count
        if let date = MessageQueue.shared.lastSuccessfulForward() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lastForwarded = formatter.localizedString(for: date, relativeTo: Date())
        } else {
            lastForwarded = "Never"
        }
    }

    func flushQueueIfNeeded() {
        guard MessageQueue.shared.count > 0, forwardEmail.contains("@") else { return }

        let messages = MessageQueue.shared.dequeueAll()
        guard !messages.isEmpty else { return }

        ForwardMessageHelper.shared.forwardBatch(messages: messages, to: forwardEmail) { success, error in
            if !success {
                // Requeue failed messages
                let failed = messages.map { msg -> QueuedMessage in
                    var m = msg
                    m.retryCount += 1
                    m.lastError = error
                    return m
                }
                MessageQueue.shared.requeueFailed(failed.filter { $0.retryCount < 10 })
                MessageQueue.shared.logEvent(.failed, detail: "App-open flush failed: \(error)")
            }
            DispatchQueue.main.async {
                refreshStatus()
                // Re-check auth status if flush failed due to auth
                if !success && (error.contains("invalid_grant") || error.contains("expired")) {
                    authStatus = .expired
                }
            }
        }
    }

    func sendTestMessage() {
        guard forwardEmail.contains("@") else {
            testStatus = "Please enter a valid email first"
            return
        }

        testStatus = "Sending..."
        ForwardMessageHelper.shared.forward(
            message: "This is a test from Forward Text app. If you received this, the forwarding is working!",
            sender: "Test",
            to: forwardEmail
        ) { success in
            DispatchQueue.main.async {
                testStatus = success ? "Test email sent!" : "Failed to send. Check logs for details."
                refreshStatus()
                if success {
                    authStatus = .valid
                }
            }
        }
    }
}

// MARK: - OAuth Re-authentication View

struct OAuthReauthView: View {
    @Binding var authStatus: ContentView.AuthStatus
    @Environment(\.dismiss) var dismiss
    @State private var status: String = ""
    @State private var isLoading = false

    // Use localhost redirect (registered in Google Cloud Console as Web Application client)
    private let redirectURI = "http://localhost:3000/oauth2callback"

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Re-authenticate Gmail")
                    .font(.title2.bold())

                Text("Your Gmail access token has expired. Tap below to sign in again and get a fresh token.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if isLoading {
                    ProgressView("Authenticating...")
                } else {
                    Button(action: startOAuth) {
                        Label("Sign in with Google", systemImage: "person.badge.key")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("Success") ? .green : .red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Re-authenticate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    func startOAuth() {
        guard let authURL = ForwardMessageHelper.shared.buildAuthURL(redirectURI: redirectURI) else {
            status = "Error: No client ID available. Rebuild the app."
            return
        }

        isLoading = true
        status = ""

        // Use ASWebAuthenticationSession for secure in-app OAuth
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "http"
        ) { callbackURL, error in
            DispatchQueue.main.async {
                isLoading = false

                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        status = "Sign-in cancelled"
                    } else {
                        status = "Auth error: \(error.localizedDescription)"
                    }
                    return
                }

                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    status = "Error: No authorization code received"
                    return
                }

                // Exchange code for tokens
                isLoading = true
                ForwardMessageHelper.shared.exchangeCodeForTokens(code: code, redirectURI: redirectURI) { success, error in
                    DispatchQueue.main.async {
                        isLoading = false
                        if success {
                            status = "Success! Gmail re-authenticated."
                            authStatus = .valid
                            MessageQueue.shared.logEvent(.tokenRefreshSuccess, detail: "User re-authenticated via in-app OAuth")
                            // Auto-dismiss after brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                dismiss()
                            }
                        } else {
                            status = "Failed: \(error ?? "Unknown error")"
                        }
                    }
                }
            }
        }

        session.prefersEphemeralWebBrowserSession = false // Allow existing Google session
        session.presentationContextProvider = OAuthPresentationContext.shared
        session.start()
    }
}

// ASWebAuthenticationSession needs a presentation context
class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Logs View

struct LogsView: View {
    @State private var logs: [MessageQueue.LogEntry] = []

    var body: some View {
        NavigationStack {
            List(logs.reversed(), id: \.timestamp) { log in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(colorForEvent(log.event))
                            .frame(width: 8, height: 8)
                        Text(log.event.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(colorForEvent(log.event))
                        Spacer()
                        Text(formatTime(log.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let sender = log.sender {
                        Text(sender)
                            .font(.caption.bold())
                    }
                    Text(log.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("Forwarding Logs")
            .onAppear {
                logs = MessageQueue.shared.recentLogs(limit: 50)
            }
        }
    }

    func colorForEvent(_ event: MessageQueue.EventType) -> Color {
        switch event {
        case .queued: return .blue
        case .sent, .tokenRefreshSuccess, .flushCompleted: return .green
        case .failed, .tokenRefreshFailed, .networkError: return .red
        case .retrying, .flushStarted: return .orange
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm:ss a"
        return formatter.string(from: date)
    }
}

// MARK: - Setup Guide

struct SetupGuideView: View {
    @Binding var isSetup: Bool
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Setup Guide")
                        .font(.title2.bold())

                    Text("Step 1: Message Automation")
                        .font(.headline)
                    StepView(number: 1, text: "Open Shortcuts app \u{2192} Automation tab")
                    StepView(number: 2, text: "Create automation: When I Receive a Message")
                    StepView(number: 3, text: "Turn on 'Run Immediately'")
                    StepView(number: 4, text: "Add action: Forward Text \u{2192} 'Forward Message'")
                    StepView(number: 5, text: "Set Message Content to 'Shortcut Input'")

                    Divider()

                    Text("Step 2: Flush Timer (Shortcut Plus)")
                        .font(.headline)
                    StepView(number: 6, text: "In Shortcut Plus, create a recurring timer (every 5 min)")
                    StepView(number: 7, text: "Set it to run: Forward Text \u{2192} 'Send Queued Messages'")
                    StepView(number: 8, text: "This sends any queued texts to your email in batches")

                    Divider()

                    Text("How It Works")
                        .font(.headline)
                    Text("Each incoming text is instantly saved to a local queue (no network needed). Every 5 minutes, the flush action sends all queued messages in one email. This prevents iOS from throttling the automation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: {
                        isSetup = true
                        dismiss()
                    }) {
                        Text("I've completed the setup")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.top)
                }
                .padding()
            }
            .navigationTitle("Setup Guide")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct StepView: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())
            Text(text)
                .font(.body)
        }
    }
}
