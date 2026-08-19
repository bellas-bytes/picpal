import AVFoundation
import os

/// Speaks coaching cues on-device using `AVSpeechSynthesizer`.
///
/// Thread-safe: `speak(_:)` may be called from any thread.
/// Respects priority: a cue with a lower `CuePriority.rawValue` (= higher importance)
/// interrupts an in-progress utterance of lesser importance; equal or lower priority
/// does not interrupt.
public final class VoiceCoach: NSObject, @unchecked Sendable {

    // MARK: - Named constants (no magic numbers)

    public static let defaultRate: Float = 0.52
    public static let defaultPitchMultiplier: Float = 1.0
    public static let defaultVolume: Float = 1.0

    // MARK: - Private state

    private let synthesizer = AVSpeechSynthesizer()
    private let rate: Float
    private let pitchMultiplier: Float
    private let volume: Float

    /// Lock protecting all mutable fields below.
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var isMuted: Bool = false
        var currentPriority: CuePriority? = nil
        var speakCount: Int = 0
    }

    // MARK: - Init

    public init(
        rate: Float = VoiceCoach.defaultRate,
        pitchMultiplier: Float = VoiceCoach.defaultPitchMultiplier,
        volume: Float = VoiceCoach.defaultVolume
    ) {
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.volume = volume
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - API

    /// Attempt to speak `cue`. Interrupts a lower-priority in-progress utterance.
    /// Does nothing if `isMuted` is true.
    public func speak(_ cue: Cue) {
        let shouldSpeak = lock.withLock { state -> Bool in
            guard !state.isMuted else { return false }

            if let current = state.currentPriority {
                // Only interrupt if the new cue has strictly higher priority (lower rawValue).
                guard cue.priority < current else { return false }
                // Will interrupt — currentPriority is updated after speak() returns (see below).
            }

            state.speakCount += 1
            return true
        }

        guard shouldSpeak else { return }

        let utterance = makeUtterance(for: cue.text)

        // Stop any in-progress utterance (safe to call even if nothing is playing).
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)

        // Set currentPriority AFTER speak() returns so that any didFinish/didCancel
        // fired by the previous utterance (during stopSpeaking or speak) cannot
        // overwrite the new priority.
        lock.withLock { $0.currentPriority = cue.priority }
    }

    /// Immediately stop any in-progress utterance.
    public func stop() {
        lock.withLock { state in
            state.currentPriority = nil
        }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Mute/unmute voice output. When muted, `speak(_:)` is a no-op.
    ///
    /// Transitioning from unmuted → muted also stops any utterance currently playing,
    /// so audio does not continue to the end of an in-flight cue.
    public var isMuted: Bool {
        get { lock.withLock { $0.isMuted } }
        set {
            let wasUnmuted = lock.withLock { state in
                let was = !state.isMuted
                state.isMuted = newValue
                return was
            }
            if newValue && wasUnmuted {
                stop()
            }
        }
    }

    // MARK: - Internal test hooks

    /// Number of utterances actually dispatched to the synthesizer.
    /// Protected by the same lock. Visible in test target via `@testable import PicPal`.
    internal var speakCount: Int {
        lock.withLock { $0.speakCount }
    }

    /// Priority of the utterance currently being spoken (nil if idle).
    internal var currentPriority: CuePriority? {
        lock.withLock { $0.currentPriority }
    }

    // MARK: - Private helpers

    private func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        return utterance
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceCoach: AVSpeechSynthesizerDelegate {

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        lock.withLock { $0.currentPriority = nil }
    }

    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        lock.withLock { $0.currentPriority = nil }
    }
}
