import Foundation
#if canImport(os)
import os
#endif

public enum PMLoggingPackage {
    public static let name = "PMLogging"
}

/// The category table of `specs/07-CLIENT.md` section 5.
public enum LogCategory: String, CaseIterable, Sendable, Hashable {
    case session, resort, meet, solver, map, realtime, location, activity, network, outbox
}

public enum LogLevel: Int, Sendable, Hashable, Comparable {
    case debug, info, notice, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        }
    }
}

public struct LogEntry: Sendable, Hashable {
    public var at: Date
    public var category: LogCategory
    public var level: LogLevel
    public var message: String

    public init(at: Date, category: LogCategory, level: LogLevel, message: String) {
        self.at = at
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Receives every entry as well as the system log: the flight recorder.
public protocol LogSink: Sendable {
    func record(_ entry: LogEntry)
}

/// Logs through `os.Logger` where it exists and into an optional sink everywhere.
/// Messages are logged as public: callers keep names, tokens and coordinates out.
public struct PMLog: Sendable {
    public static let defaultSubsystem = "com.powdermeet.app"

    private let sink: (any LogSink)?
    #if canImport(os)
    private let loggers: [LogCategory: Logger]
    #endif

    public init(subsystem: String = PMLog.defaultSubsystem, sink: (any LogSink)? = nil) {
        self.sink = sink
        #if canImport(os)
        var loggers: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        self.loggers = loggers
        #endif
    }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        #if canImport(os)
        let type: OSLogType = switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
        loggers[category]?.log(level: type, "\(message, privacy: .public)")
        #endif
        sink?.record(LogEntry(at: Date(), category: category, level: level, message: message))
    }

    public func debug(_ category: LogCategory, _ message: String) { log(.debug, category, message) }
    public func info(_ category: LogCategory, _ message: String) { log(.info, category, message) }
    public func notice(_ category: LogCategory, _ message: String) { log(.notice, category, message) }
    public func error(_ category: LogCategory, _ message: String) { log(.error, category, message) }
    public func fault(_ category: LogCategory, _ message: String) { log(.fault, category, message) }
}
