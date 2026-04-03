import Foundation

/// Persistent message queue that survives app termination.
/// Messages are saved to a shared JSON file so both the app and Shortcuts intent can access them.
struct QueuedMessage: Codable, Identifiable {
    let id: UUID
    let sender: String
    let message: String
    let timestamp: Date
    var retryCount: Int
    var lastError: String?

    init(sender: String, message: String) {
        self.id = UUID()
        self.sender = sender
        self.message = message
        self.timestamp = Date()
        self.retryCount = 0
        self.lastError = nil
    }
}

/// Thread-safe persistent message queue backed by a JSON file in the app's shared container.
class MessageQueue {
    static let shared = MessageQueue()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.forwardtext.messagequeue")

    private var queueFileURL: URL {
        // Use app group container if available, otherwise Documents
        let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("message_queue.json")
    }

    private var logFileURL: URL {
        let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("forward_log.json")
    }

    // MARK: - Queue Operations

    func enqueue(_ message: QueuedMessage) {
        queue.sync {
            var messages = loadMessages()
            messages.append(message)
            saveMessages(messages)
        }
        logEvent(.queued, sender: message.sender, detail: "Message queued for delivery")
    }

    func dequeueAll() -> [QueuedMessage] {
        return queue.sync {
            let messages = loadMessages()
            saveMessages([])
            return messages
        }
    }

    func peek() -> [QueuedMessage] {
        return queue.sync { loadMessages() }
    }

    func requeueFailed(_ messages: [QueuedMessage]) {
        queue.sync {
            var current = loadMessages()
            current.append(contentsOf: messages)
            saveMessages(current)
        }
    }

    var count: Int {
        return queue.sync { loadMessages().count }
    }

    // MARK: - Logging

    enum EventType: String, Codable {
        case queued
        case sent
        case failed
        case retrying
        case tokenRefreshFailed
        case tokenRefreshSuccess
        case networkError
        case flushStarted
        case flushCompleted
    }

    struct LogEntry: Codable {
        let timestamp: Date
        let event: EventType
        let sender: String?
        let detail: String
    }

    func logEvent(_ event: EventType, sender: String? = nil, detail: String) {
        queue.async {
            var logs = self.loadLogs()
            logs.append(LogEntry(timestamp: Date(), event: event, sender: sender, detail: detail))
            // Keep last 200 entries
            if logs.count > 200 {
                logs = Array(logs.suffix(200))
            }
            self.saveLogs(logs)
        }
    }

    func recentLogs(limit: Int = 50) -> [LogEntry] {
        return queue.sync {
            let logs = loadLogs()
            return Array(logs.suffix(limit))
        }
    }

    func lastSuccessfulForward() -> Date? {
        return queue.sync {
            let logs = loadLogs()
            return logs.last(where: { $0.event == .sent })?.timestamp
        }
    }

    // MARK: - File I/O

    private func loadMessages() -> [QueuedMessage] {
        guard let data = try? Data(contentsOf: queueFileURL),
              let messages = try? JSONDecoder().decode([QueuedMessage].self, from: data) else {
            return []
        }
        return messages
    }

    private func saveMessages(_ messages: [QueuedMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: queueFileURL, options: .atomic)
    }

    private func loadLogs() -> [LogEntry] {
        guard let data = try? Data(contentsOf: logFileURL),
              let logs = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            return []
        }
        return logs
    }

    private func saveLogs(_ logs: [LogEntry]) {
        guard let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: logFileURL, options: .atomic)
    }
}
