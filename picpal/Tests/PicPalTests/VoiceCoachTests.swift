import Testing
import AVFoundation
@testable import PicPal

// MARK: - VoiceCoachTests

/// Tests for `VoiceCoach` — mute toggle, speak count, and priority interruption logic.
///
/// `AVSpeechSynthesizer` cannot speak in a simulator test environment; these tests
/// exercise only the logic layer via internal test hooks (`speakCount`, `currentPriority`).
@MainActor
@Suite(.serialized)
struct VoiceCoachTests {

    @Test("Coaching audio uses playback so silent mode does not suppress speech")
    func speechConfiguresAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient)
        let coach = VoiceCoach()
        defer { coach.stop() }
        coach.speak(makeCue())
        #expect(session.category == .playback)
        #expect(session.mode == .spokenAudio)
        #expect(session.categoryOptions.contains(.mixWithOthers))
    }

    // MARK: - Helpers

    private func makeCue(text: String = "Test cue", priority: CuePriority = .composition) -> Cue {
        Cue(text: text, priority: priority, sourceTier: .tier0)
    }

    // MARK: - isMuted default

    @Test("VoiceCoach isMuted defaults to false")
    func isMutedDefaultsFalse() {
        let coach = VoiceCoach()
        #expect(coach.isMuted == false)
    }

    // MARK: - isMuted toggle

    @Test("VoiceCoach isMuted toggles correctly")
    func isMutedToggles() {
        let coach = VoiceCoach()
        coach.isMuted = true
        #expect(coach.isMuted == true)
        coach.isMuted = false
        #expect(coach.isMuted == false)
    }

    // MARK: - speak while muted

    @Test("speak() while muted increments no speakCount")
    func speakWhileMutedDoesNotSpeak() {
        let coach = VoiceCoach()
        coach.isMuted = true
        coach.speak(makeCue())
        #expect(coach.speakCount == 0)
    }

    // MARK: - speak while unmuted

    @Test("speak() while unmuted increments speakCount")
    func speakWhileUnmutedIncreasesSpeakCount() {
        let coach = VoiceCoach()
        coach.speak(makeCue())
        #expect(coach.speakCount == 1)
    }

    // MARK: - priority interruption

    @Test("Higher priority cue replaces lower priority current cue")
    func higherPriorityCueInterruptsLower() {
        let coach = VoiceCoach()

        // Speak a low-priority cue (aesthetic = rawValue 4, lowest priority).
        let lowPriorityCue = makeCue(text: "Aesthetic hint", priority: .aesthetic)
        coach.speak(lowPriorityCue)
        #expect(coach.speakCount == 1)
        #expect(coach.currentPriority == .aesthetic)

        // Speak a higher-priority cue (stability = rawValue 0, highest priority).
        let highPriorityCue = makeCue(text: "Hold steady", priority: .stability)
        coach.speak(highPriorityCue)
        #expect(coach.speakCount == 2)
        #expect(coach.currentPriority == .stability)
    }

    // MARK: - equal priority does not interrupt

    @Test("Equal priority cue does not interrupt in-progress utterance")
    func equalPriorityCueDoesNotInterrupt() {
        let coach = VoiceCoach()

        // Speak a composition cue.
        let firstCue = makeCue(text: "Move left", priority: .composition)
        coach.speak(firstCue)
        #expect(coach.speakCount == 1)
        #expect(coach.currentPriority == .composition)

        // Speak another composition cue (equal priority) — should be discarded.
        let secondCue = makeCue(text: "Move right", priority: .composition)
        coach.speak(secondCue)
        #expect(coach.speakCount == 1)         // no new utterance dispatched
        #expect(coach.currentPriority == .composition)
    }

    // MARK: - lower priority does not interrupt

    @Test("Lower priority cue does not interrupt higher priority utterance")
    func lowerPriorityCueDoesNotInterrupt() {
        let coach = VoiceCoach()

        // Speak a stability cue (highest priority).
        let highPriorityCue = makeCue(text: "Hold steady", priority: .stability)
        coach.speak(highPriorityCue)
        #expect(coach.speakCount == 1)
        #expect(coach.currentPriority == .stability)

        // Speak an aesthetic cue (lowest priority) — should be discarded.
        let lowPriorityCue = makeCue(text: "Nice light", priority: .aesthetic)
        coach.speak(lowPriorityCue)
        #expect(coach.speakCount == 1)         // still just one utterance
        #expect(coach.currentPriority == .stability)
    }

    // MARK: - stop clears priority

    @Test("stop() clears currentPriority")
    func stopClearsCurrentPriority() {
        let coach = VoiceCoach()
        coach.speak(makeCue(priority: .exposure))
        coach.stop()
        #expect(coach.currentPriority == nil)
    }
}
