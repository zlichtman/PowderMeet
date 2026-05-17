//
//  CryptoHelpers.swift
//  PowderMeet
//
//  Nonce generation + SHA-256 hashing utilities for Sign in with Apple.
//

import Foundation
import CryptoKit
import Security

/// Generates a cryptographically-random nonce string for use in Apple Sign In.
/// The raw nonce is sent to Apple; the SHA-256 hash is sent to Supabase.
func randomNonceString(length: Int = 32) -> String {
    precondition(length > 0)
    var randomBytes = [UInt8](repeating: 0, count: length)
    let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
    guard status == errSecSuccess else {
        fatalError("[CryptoHelpers] SecRandomCopyBytes failed with status \(status)")
    }
    let charset: [Character] =
        Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    return String(randomBytes.map { charset[Int($0) % charset.count] })
}

/// Returns the lowercase hex SHA-256 digest of `input`.
func sha256(_ input: String) -> String {
    let data = Data(input.utf8)
    let hash = SHA256.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
}
