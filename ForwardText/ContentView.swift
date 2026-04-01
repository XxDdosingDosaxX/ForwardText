import SwiftUI

struct ContentView: View {
    @AppStorage("forwardEmail") private var forwardEmail: String = ""
    @AppStorage("isSetup") private var isSetup: Bool = false
    @State private var showingSetupGuide = false
    @State private var testStatus: String = ""

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
                        Image(systemName: isSetup ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isSetup ? .green : .orange)
                        Text(isSetup ? "Shortcuts automation active" : "Set up Shortcuts automation")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                // Setup button
                Button(action: { showingSetupGuide = true }) {
                    Label("Setup Shortcuts Automation", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                // Test button
                Button(action: sendTestMessage) {
                    Label("Send Test Email", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Footer
                Text("Messages are forwarded directly from your device.\nNo data passes through external servers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom)
            }
            .navigationTitle("")
            .sheet(isPresented: $showingSetupGuide) {
                SetupGuideView(isSetup: $isSetup)
            }
        }
    }

    func sendTestMessage() {
        guard forwardEmail.contains("@") else {
            testStatus = "Please enter a valid email first"
            return
        }

        ForwardMessageHelper.shared.forward(
            message: "This is a test from Forward Text app. If you received this, the forwarding is working!",
            sender: "Test",
            to: forwardEmail
        ) { success in
            DispatchQueue.main.async {
                testStatus = success ? "Test email sent!" : "Failed to send. Check your connection."
            }
        }
    }
}

struct SetupGuideView: View {
    @Binding var isSetup: Bool
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Setup Shortcuts Automation")
                        .font(.title2.bold())

                    StepView(number: 1, text: "Open the Shortcuts app on your iPhone")
                    StepView(number: 2, text: "Tap the Automation tab at the bottom")
                    StepView(number: 3, text: "Tap + to create a New Automation")
                    StepView(number: 4, text: "Select Message as the trigger")
                    StepView(number: 5, text: "Set 'Message Contains' to a blank space (forwards all messages) or leave empty")
                    StepView(number: 6, text: "Turn on 'Run Immediately'")
                    StepView(number: 7, text: "Tap Next, then search for 'Forward Text'")
                    StepView(number: 8, text: "Select 'Forward Message' action")
                    StepView(number: 9, text: "Tap on the Message field and select 'Shortcut Input' from the toolbar")
                    StepView(number: 10, text: "Tap Done — you're all set!")

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
