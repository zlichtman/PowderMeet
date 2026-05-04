//
//  ContactsService.swift
//  PowderMeet
//
//  Wraps CNContactStore to request permission and extract contact emails
//  and phone numbers for the "People You May Know" friend-suggestion feature.
//

import Contacts
import Foundation
import Observation

@MainActor @Observable
final class ContactsService {
    static let shared = ContactsService()

    /// Current Contacts authorization status — reactive via @Observable.
    private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private init() {}

    // MARK: - Permission + Fetch

    /// Requests contacts access (if not yet determined), then returns all unique
    /// lowercase email addresses from the user's contacts.
    /// Returns [] if denied / restricted.
    func fetchContactEmails() async -> [String] {
        await ensureAuthorized()
        guard status == .authorized else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let store  = CNContactStore()
            let keys   = [CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let req    = CNContactFetchRequest(keysToFetch: keys)
            var emails = Set<String>()
            try? store.enumerateContacts(with: req) { contact, _ in
                contact.emailAddresses.forEach {
                    emails.insert(($0.value as String).lowercased())
                }
            }
            return Array(emails)
        }.value
    }

    /// Returns the union of every digits-only match candidate produced by
    /// `PhoneNormalizer` across the user's contacts. Each contact phone
    /// expands into both with-country-code and without-country-code forms
    /// so `(604) 555-1234` and `+1 604 555 1234` collapse to the same
    /// match server-side.
    func fetchContactPhones() async -> [String] {
        await ensureAuthorized()
        guard status == .authorized else { return [] }

        let region = Locale.current.region?.identifier
        return await Task.detached(priority: .userInitiated) {
            let store  = CNContactStore()
            let keys   = [CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req    = CNContactFetchRequest(keysToFetch: keys)
            var phones = Set<String>()
            try? store.enumerateContacts(with: req) { contact, _ in
                contact.phoneNumbers.forEach { num in
                    let candidates = PhoneNormalizer.candidates(
                        for: num.value.stringValue,
                        defaultRegion: region
                    )
                    phones.formUnion(candidates)
                }
            }
            return Array(phones)
        }.value
    }

    /// Fetches both emails and phones in a single contacts scan. Phones
    /// are expanded via `PhoneNormalizer` (see `fetchContactPhones`).
    func fetchContactEmailsAndPhones() async -> (emails: [String], phones: [String]) {
        await ensureAuthorized()
        guard status == .authorized else { return ([], []) }

        let region = Locale.current.region?.identifier
        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys  = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req   = CNContactFetchRequest(keysToFetch: keys)
            var emails = Set<String>()
            var phones = Set<String>()
            try? store.enumerateContacts(with: req) { contact, _ in
                contact.emailAddresses.forEach {
                    emails.insert(($0.value as String).lowercased())
                }
                contact.phoneNumbers.forEach { num in
                    let candidates = PhoneNormalizer.candidates(
                        for: num.value.stringValue,
                        defaultRegion: region
                    )
                    phones.formUnion(candidates)
                }
            }
            return (Array(emails), Array(phones))
        }.value
    }

    // MARK: - Helpers

    private func ensureAuthorized() async {
        if status == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
        }
    }

}
