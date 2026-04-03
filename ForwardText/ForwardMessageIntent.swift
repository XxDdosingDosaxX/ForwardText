import AppIntents
import Foundation
import Contacts
import UserNotifications

/// The Shortcuts action that forwards a message to email.
/// Queues the message locally first (instant, never fails), then attempts to flush
/// the entire queue. If the flush fails, messages stay queued and get retried on
/// the next incoming text.
struct ForwardMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Forward Message"
    static var description = IntentDescription("Forward a text message to your email")
    static var openAppWhenRun: Bool = false

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

        // Contact lookup
        if senderName.contains("+") || senderName.allSatisfy({ $0.isNumber || $0 == "(" || $0 == ")" || $0 == "-" || $0 == " " || $0 == "+" }) {
            if let contactName = lookupContact(phoneNumber: senderName) {
                senderName = "\(contactName) (\(senderName))"
            }
        }

        // Step 1: Queue locally (instant, no network, never fails)
        let queued = QueuedMessage(sender: senderName, message: messageContent)
        MessageQueue.shared.enqueue(queued)

        // Step 2: Attempt to flush entire queue (sends all pending messages)
        let messages = MessageQueue.shared.dequeueAll()

        guard !messages.isEmpty else {
            return .result(dialog: "Queued: \(senderName)")
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String), Never>) in
            var completed = false

            // 20s timeout — Shortcuts automations can be killed after ~25-30s
            let timeoutWork = DispatchWorkItem {
                if !completed {
                    completed = true
                    continuation.resume(returning: (false, "Timeout after 20 seconds"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeoutWork)

            ForwardMessageHelper.shared.forwardBatch(messages: messages, to: email) { success, error in
                timeoutWork.cancel()
                if !completed {
                    completed = true
                    continuation.resume(returning: (success, error))
                }
            }
        }

        if result.0 {
            return .result(dialog: "Sent \(messages.count) message(s)")
        } else {
            // Requeue failed messages with incremented retry count
            let failed = messages.map { msg -> QueuedMessage in
                var m = msg
                m.retryCount += 1
                m.lastError = result.1
                return m
            }
            let retriable = failed.filter { $0.retryCount < 10 }
            MessageQueue.shared.requeueFailed(retriable)
            MessageQueue.shared.logEvent(.failed, detail: "Flush failed: \(result.1). Requeued \(retriable.count)")

            // Notify user if queue is stuck (3+ consecutive failures on any message)
            if let maxRetries = retriable.map({ $0.retryCount }).max(), maxRetries >= 3 {
                let content = UNMutableNotificationContent()
                content.title = "Forward Text: \(retriable.count) texts stuck"
                content.body = "Messages failing to send. Open app to check."
                content.sound = .default
                let request = UNNotificationRequest(identifier: "queue-stuck", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { _ in }
            }

            return .result(dialog: "Queued (send failed, will retry)")
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

/// Standalone flush action — can be called manually from Shortcuts or the app
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

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String), Never>) in
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
            let failed = messages.map { msg -> QueuedMessage in
                var m = msg
                m.retryCount += 1
                m.lastError = result.1
                return m
            }
            let retriable = failed.filter { $0.retryCount < 10 }
            MessageQueue.shared.requeueFailed(retriable)
            return .result(dialog: "Failed: \(result.1). \(retriable.count) requeued.")
        }
    }
}

/// App Shortcuts provider
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
