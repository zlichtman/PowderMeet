import Foundation
import MountainCore
import PMLogging
import PowderMeetAPI

/// Uploads that must survive a dead signal or a killed app: descents, meet
/// progress and client events. Each item is a file; nothing is dropped silently.
/// A file that cannot be decoded moves to `corrupt/` and is logged at `.fault`; an
/// item the server refuses for good, with one of its typed refusals, moves to
/// `rejected/` and is logged at `.error`. Every other failure leaves the item
/// waiting for the next pass.
///
/// Keys make retries idempotent: enqueueing a key again replaces the waiting item
/// (the latest progress for a meet wins), and the RPCs behind every payload accept
/// a repeat (`descent_upsert` dedups, `meet_progress_update` ignores older fixes).
public actor OutboxQueue {
    public enum Payload: Codable, Sendable, Hashable {
        case descent(DescentUpload)
        case progress(ProgressUpdate)
        case clientEvent(kind: String, props: [String: JSONValue])

        public struct ProgressUpdate: Codable, Sendable, Hashable {
            public var meetID: UUID
            public var etaS: Int?
            public var etaSdS: Int?
            public var remainingM: Int?
            public var state: MeetProgressState
            public var fixAt: Date

            public init(
                meetID: UUID, etaS: Int?, etaSdS: Int?, remainingM: Int?,
                state: MeetProgressState, fixAt: Date
            ) {
                self.meetID = meetID
                self.etaS = etaS
                self.etaSdS = etaSdS
                self.remainingM = remainingM
                self.state = state
                self.fixAt = fixAt
            }
        }

        var isProgress: Bool {
            if case .progress = self { return true }
            return false
        }
    }

    public struct Item: Codable, Sendable, Hashable {
        public var key: String
        public var user: UUID
        public var sequence: Int
        public var payload: Payload
    }

    private let directory: URL
    private let legacyDirectory: URL?
    private let log: PMLog
    private var items: [Item] = []
    private var loaded = false
    private var nextSequence = 0
    private var kick: AsyncStream<Void>.Continuation?

    /// `legacyDirectory` is where an older build kept the queue; whatever is
    /// there moves into `directory` before the first read.
    public init(directory: URL, movingFrom legacyDirectory: URL? = nil, log: PMLog = PMLog()) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.log = log
    }

    public var pending: [Item] {
        loadIfNeeded()
        return items
    }

    /// Persists the item and wakes the drain loop.
    public func enqueue(key: String, user: UUID, _ payload: Payload) {
        loadIfNeeded()
        if let index = items.firstIndex(where: { $0.key == key && $0.user == user }) {
            items[index].payload = payload
            persist(items[index])
        } else {
            let item = Item(key: key, user: user, sequence: nextSequence, payload: payload)
            nextSequence += 1
            items.append(item)
            persist(item)
        }
        kick?.yield()
    }

    /// Wakes the drain loop, for example when the network returns.
    public func wake() { kick?.yield() }

    /// The account was deleted: its queued uploads (whole GPS tracks among
    /// them) and the ones the server refused can never be sent, and nothing of
    /// a deleted account may stay on the phone. Files in `corrupt/` cannot be
    /// read to say whose they are, and can never be sent either, so they all
    /// go. Other accounts' queued items stay.
    public func discard(user: UUID) {
        // Also moves a queue an older build left in Caches, so it is swept too.
        loadIfNeeded()
        let files = FileManager.default
        for item in items where item.user == user {
            remove(url(for: item))
        }
        items.removeAll { $0.user == user }
        let rejected = directory.appendingPathComponent("rejected", isDirectory: true)
        for file in contents(of: rejected) {
            do {
                let item = try WireCoding.decoder().decode(Item.self, from: Data(contentsOf: file))
                if item.user == user { remove(file) }
            } catch {
                // Unreadable, so nobody's to keep: it can never be sent.
                remove(file)
            }
        }
        let corrupt = directory.appendingPathComponent("corrupt", isDirectory: true)
        if files.fileExists(atPath: corrupt.path) { remove(corrupt) }
        log.info(.outbox, "discarded a deleted account's uploads")
    }

    private func contents(of folder: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            log.error(.outbox, "could not list \(folder.lastPathComponent): \(error)")
            return []
        }
    }

    private func remove(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            log.error(.outbox, "could not remove \(file.lastPathComponent): \(error)")
        }
    }

    /// Sends this user's items in order until cancelled. One loop runs per
    /// signed-in session; cancelling it is how sign-out stops uploads.
    public func run(backend: any BackendClient, user: UUID) async {
        let (kicks, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        kick = continuation
        continuation.yield()
        for await _ in kicks {
            await drain(backend: backend, user: user)
        }
        kick = nil
    }

    /// One pass. Stops at the first failure that is not a refusal for good.
    /// Meet progress goes first: it is small and the partner is waiting on it,
    /// while a long track stuck timing out on a weak signal would hold it back
    /// for the whole meet. Every payload's RPC is idempotent, so the order
    /// between kinds does not matter to the server.
    public func drain(backend: any BackendClient, user: UUID) async {
        loadIfNeeded()
        while let item = items.first(where: { $0.user == user && $0.payload.isProgress })
            ?? items.first(where: { $0.user == user }) {
            do {
                try await Self.send(item.payload, backend: backend)
                finish(item, movedTo: nil)
            } catch {
                if Task.isCancelled { return }
                let typed = PowderMeetError(error)
                guard Self.isRefusal(typed) else {
                    if typed.isTransient || typed == .auth(.sessionExpired) {
                        log.info(.outbox, "\(item.key) waits: \(typed)")
                    } else {
                        log.error(.outbox, "\(item.key) failed for an unknown reason and waits: \(error)")
                    }
                    return
                }
                // Progress for a meet that has ended (both skiers arrived and
                // it completed first): nothing is lost, so nothing is kept.
                if item.payload.isProgress, typed == .meet(.rejected(reason: "invalid_state")) {
                    log.info(.outbox, "\(item.key) dropped: the meet is over")
                    finish(item, movedTo: nil)
                    continue
                }
                log.error(.outbox, "\(item.key) was refused and set aside: \(error)")
                finish(item, movedTo: "rejected")
            }
        }
    }

    /// Only a refusal the server names sets an item aside. Anything else (a
    /// captive portal, a cut-off answer, a status that does not say why) may
    /// pass on a later try, and the item can be the only copy of a run.
    private static func isRefusal(_ error: PowderMeetError) -> Bool {
        switch error {
        // Also what a schema cache that has not caught up answers (PGRST202/205).
        case .meet(.rejected(reason: "not_found")): false
        case .meet, .profile: true
        // The database refused the row itself (a constraint or a bad value):
        // left waiting, it would hold every upload behind it for good.
        case .network(.server(status: 422)): true
        case .auth, .network, .data, .routing, .meetRouting, .permission, .social: false
        }
    }

    private static func send(_ payload: Payload, backend: any BackendClient) async throws {
        switch payload {
        case .descent(let upload):
            _ = try await backend.descentUpsert(upload)
        case .progress(let progress):
            try await backend.meetProgressUpdate(
                meetID: progress.meetID, etaS: progress.etaS, etaSdS: progress.etaSdS,
                remainingM: progress.remainingM, state: progress.state, fixAt: progress.fixAt
            )
        case .clientEvent(let kind, let props):
            try await backend.clientEvent(kind: kind, props: props)
        }
    }

    /// Removes what was sent. An item replaced while it was in flight stays, so
    /// the newer payload goes out on the next pass.
    private func finish(_ sent: Item, movedTo folder: String?) {
        guard let index = items.firstIndex(where: { $0.key == sent.key && $0.user == sent.user })
        else { return }
        if items[index] == sent {
            items.remove(at: index)
            let file = url(for: sent)
            do {
                if let folder {
                    try move(file, to: folder)
                } else if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                log.error(.outbox, "could not clear \(sent.key): \(error)")
            }
        } else if folder != nil {
            // The refused payload is gone; the replacement gets its own attempt.
            log.info(.outbox, "\(sent.key) was replaced while its refusal arrived")
        }
    }

    // MARK: Disk

    private func url(for item: Item) -> URL {
        let name = SHA256.hex(Data("\(item.user.uuidString)|\(item.key)".utf8)).prefix(40)
        return directory.appendingPathComponent("\(name).json")
    }

    private func move(_ file: URL, to folder: String) throws {
        let target = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let destination = target.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private func persist(_ item: Item) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try WireCoding.encoder().encode(item).write(to: url(for: item), options: .atomic)
        } catch {
            // The item stays in memory and is still sent; it would not survive a kill.
            log.fault(.outbox, "could not persist \(item.key): \(error)")
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        adoptLegacyQueue()
        let files: [URL]
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            log.fault(.outbox, "could not list the outbox: \(error)")
            return
        }
        for file in files {
            do {
                items.append(try WireCoding.decoder().decode(Item.self, from: Data(contentsOf: file)))
            } catch {
                log.fault(.outbox, "\(file.lastPathComponent) is unreadable and was set aside: \(error)")
                do {
                    try move(file, to: "corrupt")
                } catch {
                    log.fault(.outbox, "could not set \(file.lastPathComponent) aside: \(error)")
                }
            }
        }
        items.sort { $0.sequence < $1.sequence }
        nextSequence = (items.last?.sequence ?? -1) + 1
    }

    /// Older builds kept the queue in Caches, which iOS may empty under storage
    /// pressure. What cannot move now stays where it is and is moved on the next
    /// launch, so nothing queued is lost on the way.
    private func adoptLegacyQueue() {
        let files = FileManager.default
        guard let legacyDirectory, legacyDirectory != directory, files.fileExists(atPath: legacyDirectory.path)
        else { return }
        do {
            if files.fileExists(atPath: directory.path) {
                try Self.merge(legacyDirectory, into: directory)
                try files.removeItem(at: legacyDirectory)
            } else {
                try files.createDirectory(
                    at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.moveItem(at: legacyDirectory, to: directory)
            }
            log.info(.outbox, "moved the outbox out of the cache")
        } catch {
            log.fault(.outbox, "could not move the outbox out of the cache: \(error)")
        }
    }

    /// Moves every file under `source` to the same place under `target`,
    /// `rejected/` and `corrupt/` included. A file already in `target` was
    /// queued after an earlier move stopped part-way, so it is the newer copy
    /// of that item and is kept.
    private static func merge(_ source: URL, into target: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for entry in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destination = target.appendingPathComponent(entry.lastPathComponent)
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try merge(entry, into: destination)
                try files.removeItem(at: entry)
            } else if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: entry)
            } else {
                try files.moveItem(at: entry, to: destination)
            }
        }
    }
}
