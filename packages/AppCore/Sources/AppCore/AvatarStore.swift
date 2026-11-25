import Foundation
import PMLogging
import PowderMeetAPI

/// Profile photos on disk, keyed by their object path in the `avatars` bucket.
/// A path names its bytes (every upload gets a new one), so a stored file is
/// never stale and is kept until it falls out of the most recently used
/// `capacity`, or the user signs out. Concurrent asks for one path share one
/// download.
public actor AvatarStore {
    public nonisolated let directory: URL
    public nonisolated let capacity: Int
    private let log: PMLog
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(directory: URL, capacity: Int = 400, log: PMLog = PMLog()) {
        self.directory = directory
        self.capacity = capacity
        self.log = log
    }

    /// The photo at `path`: from disk, else downloaded and kept. Nil for a
    /// path that is not an avatar path or could not be had now (it is asked
    /// for again next time).
    public func data(for path: String, from backend: any BackendClient) async -> Data? {
        guard AvatarPath.isWellFormed(path) else { return nil }
        let file = url(for: path)
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                touch(file)
                return data
            } catch {
                log.notice(.network, "avatar cache unreadable, downloading again: \(error)")
            }
        }
        if let running = inFlight[path] { return await running.value }
        let log = log
        let task = Task<Data?, Never> {
            do {
                return try await backend.avatarData(path: path)
            } catch {
                if !Task.isCancelled { log.info(.network, "avatar not downloaded: \(error)") }
                return nil
            }
        }
        inFlight[path] = task
        let data = await task.value
        // `clear()` (a sign-out) empties the table while the download runs:
        // its answer then belongs to a session that is over and is not kept.
        guard inFlight[path] == task else { return data }
        inFlight[path] = nil
        if let data { store(data, at: file) }
        return data
    }

    /// Forgets one photo: the user's own after they replace or remove it.
    public func remove(path: String) {
        guard AvatarPath.isWellFormed(path) else { return }
        let file = url(for: path)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            log.notice(.network, "old avatar not removed from the cache: \(error)")
        }
    }

    /// Removes every stored photo not at one of `paths`: a person who replaced
    /// or removed their photo, deleted their account, or is no longer listed
    /// leaves nothing behind on this phone. Photos shown elsewhere (a search
    /// result) are downloaded again when next asked for.
    public func retain(paths: Set<String>) {
        let kept = Set(paths.filter(AvatarPath.isWellFormed).map { url(for: $0).lastPathComponent })
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            // No folder yet, or it was just cleared: nothing to remove.
            return
        }
        for file in files where !kept.contains(file.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                log.notice(.network, "unlisted avatar not removed from the cache: \(error)")
            }
        }
    }

    /// Keeps bytes the app already has (its own new photo), so showing them
    /// needs no download.
    public func keep(_ data: Data, for path: String) {
        guard AvatarPath.isWellFormed(path) else { return }
        store(data, at: url(for: path))
    }

    /// Removes every stored photo: other people's faces do not outlive the
    /// session that was allowed to see them.
    public func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            log.error(.session, "avatar cache not removed: \(error)")
        }
    }

    /// `<folder>_<file>`: the path's two parts are letters, digits, `.`, `_`
    /// and `-` only (`AvatarPath.isWellFormed`), so this cannot leave the directory.
    private func url(for path: String) -> URL {
        directory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private func store(_ data: Data, at file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            trim()
        } catch {
            log.notice(.network, "avatar not cached: \(error)")
        }
    }

    /// Marks a file as just used, for `trim`.
    private func touch(_ file: URL) {
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } catch {
            log.info(.network, "avatar cache date not updated: \(error)")
        }
    }

    /// Drops the least recently used files beyond `capacity`.
    private func trim() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count > capacity else { return }
            // File attributes rather than URL resource values: the same on Linux CI.
            let dated = try files.map { file in
                (file, try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                    ?? .distantPast)
            }
            for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            log.notice(.network, "avatar cache not trimmed: \(error)")
        }
    }
}
