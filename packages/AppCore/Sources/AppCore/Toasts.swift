import Foundation
import PMLogging
import Synchronization

public struct Toast: Identifiable, Hashable, Sendable {
    /// What the message is about, for its icon and whether VoiceOver hears it
    /// without the skier going to it.
    public enum Kind: Hashable, Sendable {
        case notice
        /// A badge just earned (`BadgeMoments`).
        case badge
    }

    public var id: UUID
    public var message: String
    public var recovery: Recovery
    public var kind: Kind

    public init(id: UUID = UUID(), message: String, recovery: Recovery = .none, kind: Kind = .notice) {
        self.id = id
        self.message = message
        self.recovery = recovery
        self.kind = kind
    }
}

/// Transient messages, oldest first. A message already waiting is not queued twice.
public actor Toasts {
    public private(set) var queue: [Toast] = []
    private let changes = Multicast<[Toast]>()

    public init() {}

    public func post(_ error: PowderMeetError) {
        post(message: error.userMessage, recovery: error.recovery)
    }

    public func post(message: String, recovery: Recovery = .none, kind: Toast.Kind = .notice) {
        guard !queue.contains(where: { $0.message == message }) else { return }
        queue.append(Toast(message: message, recovery: recovery, kind: kind))
        changes.send(queue)
    }

    public func dismiss(_ id: UUID) {
        queue.removeAll { $0.id == id }
        changes.send(queue)
    }

    public func updates() -> AsyncStream<[Toast]> { changes.stream(initial: queue) }
}

/// The last 2,000 log entries at `.info` and above, for a bug report.
public final class FlightRecorder: LogSink {
    public static let capacity = 2_000

    private struct Ring {
        var entries: [LogEntry] = []
        var next = 0
    }

    private let ring = Mutex(Ring())

    public init() {}

    public func record(_ entry: LogEntry) {
        guard entry.level >= .info else { return }
        ring.withLock { ring in
            if ring.entries.count < Self.capacity {
                ring.entries.append(entry)
            } else {
                ring.entries[ring.next] = entry
                ring.next = (ring.next + 1) % Self.capacity
            }
        }
    }

    /// Oldest first.
    public var entries: [LogEntry] {
        ring.withLock { Array($0.entries[$0.next...] + $0.entries[..<$0.next]) }
    }

    /// The buffer as text with identifiers shortened and coordinates and email
    /// addresses removed.
    public func export() -> String {
        entries.map { entry in
            "\(Self.timestamp(entry.at)) [\(entry.category.rawValue)] \(entry.level.label): "
                + Self.redact(entry.message)
        }.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func redact(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            // A UUID keeps its first block so entries can still be correlated.
            ("([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "$1…"),
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<email>"),
            ("-?[0-9]{1,3}\\.[0-9]{4,}", "<coord>"),
            ("[0-9a-fA-F]{32,}", "<token>"),
        ]
        for (pattern, template) in rules {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                continue
            }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template
            )
        }
        return out
    }
}
