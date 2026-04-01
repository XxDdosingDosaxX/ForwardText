import AppIntents
import Foundation

/// The Shortcuts action that forwards a message to email.
/// This is what gets triggered by the Shortcuts automation when a message is received.
struct ForwardMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Forward Message"
    static var description = IntentDescription("Forward a text message to your email")
    static var openAppWhenRun: Bool = false  // Run silently in background

    @Parameter(title: "Message Content")
    var messageContent: String

    @Parameter(title: "Sender", default: "Unknown")
    var sender: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let email = UserDefaults.standard.string(forKey: "forwardEmail") ?? ""

        guard !email.isEmpty else {
            return .result(dialog: "Please set up your email in the Forward Text app first.")
        }

        let senderName = sender ?? "Unknown"
        let success = await withCheckedContinuation { continuation in
            ForwardMessageHelper.shared.forward(
                message: messageContent,
                sender: senderName,
                to: email
            ) { result in
                continuation.resume(returning: result)
            }
        }

        if success {
            return .result(dialog: "Message forwarded to \(email)")
        } else {
            return .result(dialog: "Failed to forward message")
        }
    }
}

/// App Shortcuts provider — makes the intent discoverable in Shortcuts app
struct ForwardTextShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ForwardMessageIntent(),
            phrases: [
                "Forward message with \(.applicationName)",
                "Forward text with \(.applicationName)",
                "Send text to email with \(.applicationName)"
            ],
            shortTitle: "Forward Message",
            systemImageName: "message.badge.filled.fill"
        )
    }
}
