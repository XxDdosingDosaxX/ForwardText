import AppIntents
import Foundation
import Contacts

/// The Shortcuts action that queues a message for forwarding.
/// This runs instantly (no network) so iOS won't throttle it.
struct ForwardMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Forward Message"
    static var description = IntentDescription("Queue a text message for email forwarding")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Message Content")
    var messageContent: String

    @Parameter(title: "Sender", default: "Unknown")
    var sender: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var senderName = sender ?? "Unknown"

        // Contact lookup with timeout protection
        if senderName.contains("+") || senderName.allSatisfy({ $0.isNumber || $0 == "(" || $0 == ")" || $0 == "-" || $0 == " " || $0 == "+" }) {
            if let contactName = lookupContact(phoneNumber: senderName) {
                senderName = "\(contactName) (\(senderName))"
            }
        }

        // Queue locally — instant, no network, never fails
        let message = QueuedMessage(sender: senderName, message: messageContent)
        MessageQueue.shared.enqueue(message)

        return .result(dialog: "Queued: \(senderName)")
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

/// Shortcuts action to flush the queue — send all queued messages via email.
/// Called by Shortcut Plus on a 5-minute timer.
struct FlushQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Queued Messages"
    static var description = IntentDescription("Send all queued text messages to email")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let email = UserDefaults.standard.string(forKey: "forwardEmail") ?? ""

        guard !email.isEmpty else {
            return .result(dialog: "No email configured")
        }

        let messages = MessageQueue.shared.dequeueAll()

        guard !messages.isEmpty else {
            return .result(dialog: "Queue empty")
        }

        MessageQueue.shared.logEvent(.flushStarted, detail: "Flushing \(messages.count) messages")

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String), Never>) in
            // Send with timeout
            var completed = false
            let timeoutWork = DispatchWorkItem {
                if !completed {
                    completed = true
                    continuation.resume(returning: (false, "Timeout after 25 seconds"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeoutWork)

            ForwardMessageHelper.shared.forwardBatch(messages: messages, to: email) { success, error in
                timeoutWork.cancel()
                if !completed {
                    completed = true
                    continuation.resume(returning: (success, error))
                }
            }
        }

        if result.0 {
            MessageQueue.shared.logEvent(.flushCompleted, detail: "Sent \(messages.count) messages")
            return .result(dialog: "Sent \(messages.count) messages")
        } else {
            // Requeue with incremented retry count
            let failed = messages.map { msg -> QueuedMessage in
                var m = msg
                m.retryCount += 1
                m.lastError = result.1
                return m
            }
            // Drop messages that have failed 10+ times
            let retriable = failed.filter { $0.retryCount < 10 }
            let dropped = failed.count - retriable.count
            MessageQueue.shared.requeueFailed(retriable)
            MessageQueue.shared.logEvent(.failed, detail: "Failed: \(result.1). Requeued \(retriable.count), dropped \(dropped)")
            return .result(dialog: "Failed: \(result.1). \(retriable.count) requeued.")
        }
    }
}

/// App Shortcuts provider — makes both intents discoverable in Shortcuts app
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
        AppShortcut(
            intent: FlushQueueIntent(),
            phrases: [
                "Send queued messages with \(.applicationName)",
                "Flush text queue with \(.applicationName)"
            ],
            shortTitle: "Send Queued Messages",
            systemImageName: "paperplane.fill"
        )
    }
}
