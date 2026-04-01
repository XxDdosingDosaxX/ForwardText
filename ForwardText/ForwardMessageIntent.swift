import AppIntents
import Foundation
import Contacts

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

        var senderName = sender ?? "Unknown"

        // If sender looks like a phone number, try to find contact name
        if senderName.contains("+") || senderName.allSatisfy({ $0.isNumber || $0 == "(" || $0 == ")" || $0 == "-" || $0 == " " || $0 == "+" }) {
            if let contactName = lookupContact(phoneNumber: senderName) {
                senderName = "\(contactName) (\(senderName))"
            }
        }

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

    private func lookupContact(phoneNumber: String) -> String? {
        let store = CNContactStore()
        let digits = phoneNumber.filter { $0.isNumber }
        guard digits.count >= 7 else { return nil }

        let keysToFetch = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        var matchedName: String?
        try? store.enumerateContacts(with: request) { contact, stop in
            for phone in contact.phoneNumbers {
                let contactDigits = phone.value.stringValue.filter { $0.isNumber }
                // Match last 10 digits (ignoring country code differences)
                let matchLength = min(10, min(digits.count, contactDigits.count))
                if digits.suffix(matchLength) == contactDigits.suffix(matchLength) && matchLength >= 7 {
                    let fullName = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !fullName.isEmpty {
                        matchedName = fullName
                        stop.pointee = true
                    }
                }
            }
        }
        return matchedName
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
