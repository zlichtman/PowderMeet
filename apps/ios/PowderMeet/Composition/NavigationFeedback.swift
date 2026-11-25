import AppCore
import AudioToolbox
import AVFoundation
import CoreHaptics
import Foundation
import MeetSolver
import MountainCore
import PMLogging
import UIKit

/// The one "sounds and voice" switch: spoken turn prompts and the arrival bell.
/// Haptics are not behind it. Stored on this phone only, default on. The later
/// Settings page reads and writes `isOn`; nothing else needs to change.
nonisolated struct SoundsAndVoicePreference: Sendable {
    static let key = "pm.navigation.soundsAndVoice"

    // UserDefaults is thread-safe for these calls but is not marked Sendable.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Plays the cues of an active meet: a soft tap and a short spoken prompt for each new
/// instruction, a rigid double tap on leaving the route, and the arrival
/// pattern with the bell, once a meet (on arriving, or on the meet completing
/// when that comes first). One per meet, owned by its `MeetModel`.
final class NavigationFeedback {
    private let preference: SoundsAndVoicePreference
    private let log: PMLog?
    private var cues = NavigationCues()

    private var engine: CHHapticEngine?
    private let speech = AVSpeechSynthesizer()
    private let speechDelegate: SpeechDelegate

    init(preference: SoundsAndVoicePreference = SoundsAndVoicePreference(), log: PMLog? = nil) {
        self.preference = preference
        self.log = log
        speechDelegate = SpeechDelegate(onIdle: { @Sendable in
            Task { @MainActor in NavigationFeedback.releaseAudio() }
        })
        speech.delegate = speechDelegate
    }

    /// Called with every meet state; says each change once.
    func observe(_ state: MeetSession.State) {
        var rang = false
        // Said with the instruction that follows it, as one prompt: a second
        // prompt would cut the first off.
        var reroute: String?
        for cue in cues.next(state) {
            switch cue {
            case .rerouted(let easiestWayDown):
                reroute = Self.spokenReroute(easiestWayDown)
            case .instruction(let maneuver):
                play(.soft)
                let instruction = MeetPresentation.spokenInstruction(maneuver)
                say(reroute.map { "\($0) \(instruction)" } ?? instruction)
                reroute = nil
            case .offRoute:
                play(.rigid)
            case .arrived:
                play(.arrival)
                ring()
                rang = true
            }
        }
        if let reroute {
            play(.soft)
            say(reroute)
        }
        // A meet that completes as the skier arrives ends in the same moment:
        // the arrival pattern plays out, and the engine shuts itself down.
        if case .ended = state { stop(cuttingHaptics: !rang) }
    }

    /// A route above the skier's level is said out loud: the card that shows
    /// it may be put away.
    private static func spokenReroute(_ easiestWayDown: Difficulty?) -> String {
        guard let hardest = easiestWayDown else { return "New route." }
        return "New route. The only way down has \(hardest.displayName.lowercased()) runs."
    }

    private func stop(cuttingHaptics: Bool) {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        if cuttingHaptics { engine?.stop() }
    }

    // MARK: Haptics

    private enum Pattern { case soft, rigid, arrival }

    private func play(_ pattern: Pattern) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try startedEngine()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events(pattern), parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log?.info(.meet, "haptic failed, using UIKit feedback: \(error)")
            fallback(pattern)
        }
    }

    private func startedEngine() throws -> CHHapticEngine {
        if let engine {
            try engine.start()
            return engine
        }
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        // Called on the engine's own queue: only hop back to forget it.
        engine.resetHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.engine = nil }
        }
        try engine.start()
        self.engine = engine
        return engine
    }

    private func events(_ pattern: Pattern) -> [CHHapticEvent] {
        func tap(_ intensity: Float, _ sharpness: Float, at time: TimeInterval) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
        }
        return switch pattern {
        case .soft: [tap(0.4, 0.3, at: 0)]
        case .rigid: [tap(0.8, 0.7, at: 0), tap(0.8, 0.7, at: 0.18)]
        // Arrival: rigid, then success 400 ms later.
        case .arrival: [tap(1.0, 0.9, at: 0), tap(0.6, 0.5, at: 0.4), tap(1.0, 0.9, at: 0.52)]
        }
    }

    private func fallback(_ pattern: Pattern) {
        switch pattern {
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .arrival: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Voice and bell

    /// Only the newest prompt matters: a stale one is cut off.
    private func say(_ text: String) {
        guard preference.isOn, !text.isEmpty else { return }
        do {
            // Ducks music and spoken audio while the prompt plays.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
        } catch {
            log?.info(.meet, "audio session unavailable for a prompt: \(error)")
            return
        }
        if speech.isSpeaking { speech.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speech.speak(utterance)
    }

    /// Other audio comes back to full volume once the prompt is over.
    private static func releaseAudio() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Another prompt started meanwhile; it releases the session when done.
        }
    }

    /// The arrival bell. A system sound: it respects the silent switch. It
    /// rings once a meet and is freed when it has played, so the meet ending
    /// at the same moment does not cut it off.
    private func ring() {
        guard preference.isOn else { return }
        guard let url = Bundle.main.url(forResource: "arrival_bell", withExtension: "caf") else {
            log?.error(.meet, "arrival_bell.caf is not in the app")
            return
        }
        var bell: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &bell) == kAudioServicesNoError else {
            log?.error(.meet, "arrival bell could not be loaded")
            return
        }
        AudioServicesPlaySystemSoundWithCompletion(bell) { AudioServicesDisposeSystemSoundID(bell) }
    }
}

/// Tells the feedback when the synthesizer has nothing left to say. Its
/// callbacks arrive off the main actor.
private nonisolated final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onIdle: @Sendable () -> Void

    init(onIdle: @escaping @Sendable () -> Void) {
        self.onIdle = onIdle
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { onIdle() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { onIdle() }
    }
}
