import SwiftUI

struct ContentView: View {
    @AppStorage("forwardEmail") private var forwardEmail: String = ""
    @AppStorage("isSetup") private var isSetup: Bool = false
    @State private var showingSetupGuide = false
    @State private var showingLogs = false
    @State private var testStatus: String = ""
    @State private var queueCount: Int = 0
    @State private var lastForwarded: String = "Never"

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
                        let hasGmail = ForwardMessageHelper.shared.getKeychainValue(key: "refreshToken") != nil
                        Image(systemName: hasGmail ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hasGmail ? .green : .red)
                        Text(hasGmail ? "Gmail connected" : "Gmail not connected")
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

                    Button(action: { showingLogs = true }) {
                        Label("View Logs", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Messages are forwarded directly from your device.\nNo data passes through external servers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
            }
            .navigationTitle("")
            .onAppear { refreshStatus() }
            .sheet(isPresented: $showingSetupGuide) {
                SetupGuideView(isSetup: $isSetup)
            }
            .sheet(isPresented: $showingLogs) {
                LogsView()
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
            }
        }
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
                    StepView(number: 1, text: "Open Shortcuts app → Automation tab")
                    StepView(number: 2, text: "Create automation: When I Receive a Message")
                    StepView(number: 3, text: "Turn on 'Run Immediately'")
                    StepView(number: 4, text: "Add action: Forward Text → 'Forward Message'")
                    StepView(number: 5, text: "Set Message Content to 'Shortcut Input'")

                    Divider()

                    Text("Step 2: Flush Timer (Shortcut Plus)")
                        .font(.headline)
                    StepView(number: 6, text: "In Shortcut Plus, create a recurring timer (every 5 min)")
                    StepView(number: 7, text: "Set it to run: Forward Text → 'Send Queued Messages'")
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
