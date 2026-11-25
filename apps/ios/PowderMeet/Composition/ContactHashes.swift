import Contacts
import Foundation
import MountainCore

/// The email addresses in the address book as SHA-256 hashes, computed on this
/// phone. Only hashes are sent to `find_users`; names, numbers and addresses
/// never leave the device. The server hashes each account's own address the
/// same way (migration 0022): trimmed, lowercased, SHA-256 hex.
nonisolated struct ContactHashes: Sendable {
    nonisolated struct Denied: Error {}

    /// Where Contacts access stands, read without asking.
    nonisolated enum Access: Sendable, Hashable {
        case notDetermined, granted, denied
    }

    /// `find_users` accepts at most this many hashes per call.
    static let batchSize = 50
    /// The server allows 20 calls a minute; leave room for a second lookup.
    static let callsPerMinute = 18
    /// About 4,500 addresses, five minutes of lookups at most.
    static let maximumBatches = 90

    var emails: [String]

    /// More addresses than one lookup may send: the rest were not checked.
    var isCutShort: Bool { emails.count > Self.batchSize * Self.maximumBatches }

    func batches() -> [[String]] {
        stride(from: 0, to: min(emails.count, Self.batchSize * Self.maximumBatches), by: Self.batchSize)
            .map { Array(emails[$0..<min($0 + Self.batchSize, emails.count)]) }
    }

    static func hash(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.contains("@") else { return nil }
        return SHA256.hex(Data(value.utf8))
    }

    static var access: Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Reads and hashes the addresses off the main actor. Asks for access
    /// first only when `prompting`; otherwise anything short of granted is
    /// `Denied`.
    static func load(prompting: Bool) async throws -> ContactHashes {
        try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            switch access {
            case .granted:
                break
            case .notDetermined:
                guard prompting, try await store.requestAccess(for: .contacts) else { throw Denied() }
            case .denied:
                throw Denied()
            }
            var emails: Set<String> = []
            let request = CNContactFetchRequest(keysToFetch: [CNContactEmailAddressesKey as CNKeyDescriptor])
            try store.enumerateContacts(with: request) { contact, _ in
                for email in contact.emailAddresses {
                    if let hash = hash(email.value as String) { emails.insert(hash) }
                }
            }
            return ContactHashes(emails: emails.sorted())
        }.value
    }
}
