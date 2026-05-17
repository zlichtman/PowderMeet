//
//  AppLog.swift
//  PowderMeet
//
//  Subsystem-tagged logging. Every chatty hot path gets a category so we
//  can filter noise in Console.app instead of grepping `print` output.
//
//  - `.debug(...)` — DEBUG-only, no-op in Release. Autoclosure so the
//    interpolation is skipped entirely when compiled out.
//  - `.info(...)` — both DEBUG and Release; routed through `os.Logger`
//    so it shows up in unified logging with subsystem + category.
//  - `.error(...)` — same as `.info` but at error level.
//
//  Adding a new category: drop a `static let log = Logger(...)` into a
//  new `enum`, follow the existing methods. Don't mix categories — each
//  one corresponds to a `category:` string, which is how Console filters.
//

import OSLog

nonisolated private let appSubsystem = Bundle.main.bundleIdentifier ?? "PowderMeet"

/// `nonisolated` — every category sub-enum needs to be callable from
/// off-main-actor compute paths (solver Dijkstra, importer parsers, the
/// shared NSLock-guarded curated-resort cache). Project default actor
/// isolation is MainActor; opt out so warnings don't pile up at every
/// call site that's already correctly running in the background.
nonisolated enum AppLog {

    // Each sub-enum maps to one Logger category. Hot paths should pick
    // the closest match instead of inventing new ones; if a real new
    // domain shows up, add an enum here rather than bare `print`.

    enum map {
        private static let log = Logger(subsystem: appSubsystem, category: "map")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[map] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
        static func sourceUpdateFailed(id: String, error: Error) {
            log.error("updateSource(\(id, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
    }

    enum graph {
        private static let log = Logger(subsystem: appSubsystem, category: "graph")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[graph] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    enum realtime {
        private static let log = Logger(subsystem: appSubsystem, category: "realtime")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[realtime] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    enum supabase {
        private static let log = Logger(subsystem: appSubsystem, category: "supabase")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[supabase] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    enum importer {
        private static let log = Logger(subsystem: appSubsystem, category: "import")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[import] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    enum meet {
        private static let log = Logger(subsystem: appSubsystem, category: "meet")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[meet] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    enum routing {
        private static let log = Logger(subsystem: appSubsystem, category: "routing")
        static func debug(_ message: @autoclosure () -> String) {
            #if DEBUG
            print("[routing] \(message())")
            #endif
        }
        static func info(_ message: String)  { log.info("\(message, privacy: .public)") }
        static func error(_ message: String) { log.error("\(message, privacy: .public)") }
    }

    // MARK: - Legacy passthroughs

    /// Compat shim for existing `AppLog.mapSourceUpdateFailed(...)` callers.
    static func mapSourceUpdateFailed(id: String, error: Error) {
        map.sourceUpdateFailed(id: id, error: error)
    }
}
