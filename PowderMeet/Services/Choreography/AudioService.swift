//
//  AudioService.swift
//  PowderMeet
//
//  One-shot SFX playback via AudioServices. System sound IDs are decoded
//  natively, play with ~10ms latency, and respect the silent switch by
//  default — exactly the behaviour we want for the arrival chime.
//
//  Expected assets (drop in `PowderMeet/Resources/Sounds/`):
//   - arrival_bell.caf — 200ms synthesized 800Hz+1600Hz tone, IMA4 compressed
//
//  Missing assets fail silently — the haptic channel still fires.
//

import Foundation
import AudioToolbox

@MainActor
final class AudioService {
    static let shared = AudioService()

    enum Sound: String {
        case arrivalBell = "arrival_bell"
    }

    private var soundIDs: [Sound: SystemSoundID] = [:]
    private var userEnabled: Bool {
        // Stored in UserDefaults; respected so the user can mute without
        // killing haptics. Default on.
        UserDefaults.standard.object(forKey: "pm.audio.arrivalBellEnabled").map { $0 as? Bool ?? true } ?? true
    }

    /// Tracks sounds we've attempted to register so we don't retry every play().
    private var preloaded: Set<Sound> = []

    private init() {
        // Lazy: assets are registered on first play() to avoid a
        // CoreAudio file-I/O hit during app launch.
    }

    private func preload(_ sound: Sound) {
        guard !preloaded.contains(sound) else { return }
        preloaded.insert(sound)
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf")
            ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav")
            ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "aiff") else {
            print("[AudioService] missing asset: \(sound.rawValue).caf (drop into Resources/Sounds/)")
            return
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        if status == kAudioServicesNoError {
            soundIDs[sound] = id
        } else {
            print("[AudioService] failed to register \(sound.rawValue): status \(status)")
        }
    }

    /// Play the sound once. Respects the user's enable toggle. No-op if the
    /// asset is missing so callers can wire this in before the bundle exists.
    /// First play() for a given sound triggers asset registration.
    func play(_ sound: Sound) {
        guard userEnabled else { return }
        if !preloaded.contains(sound) { preload(sound) }
        guard let id = soundIDs[sound] else { return }
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }

    deinit {
        for id in soundIDs.values {
            AudioServicesDisposeSystemSoundID(id)
        }
    }
}
