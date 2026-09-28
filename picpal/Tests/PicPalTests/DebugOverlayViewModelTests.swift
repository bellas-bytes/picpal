import Testing
import Foundation
@testable import PicPal

@MainActor
struct DebugOverlayViewModelTests {

    @Test("A cooldown tick does not erase a readable coaching cue")
    func coachingCueSurvivesCooldown() {
        let model = DebugOverlayViewModel()
        let start = Date(timeIntervalSince1970: 100)
        let cue = Cue(text: "Tilt left a little", priority: .stability, sourceTier: .tier0)
        model.receiveCoachingCue(cue, at: start)
        model.receiveCoachingCue(nil, at: start.addingTimeInterval(0.02))
        #expect(model.activeCue == cue.text)
        model.receiveCoachingCue(nil, at: start.addingTimeInterval(4))
        #expect(model.activeCue == "—")
    }

    @Test("A new cue replaces the old instruction and gets its own reading time")
    func newCoachingCueReplacesOld() {
        let model = DebugOverlayViewModel()
        let start = Date(timeIntervalSince1970: 100)
        model.receiveCoachingCue(Cue(text: "Move left", priority: .composition, sourceTier: .tier0), at: start)
        model.receiveCoachingCue(Cue(text: "Hold still", priority: .stability, sourceTier: .tier0), at: start.addingTimeInterval(3))
        model.receiveCoachingCue(nil, at: start.addingTimeInterval(4))
        #expect(model.activeCue == "Hold still")
    }

    // MARK: - Initial placeholder values

    @Test("ViewModel initialises tiltDegrees to 0")
    func initialTiltDegrees() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.tiltDegrees == 0)
    }

    @Test("ViewModel initialises blurScore to 0")
    func initialBlurScore() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.blurScore == 0)
    }

    @Test("ViewModel initialises exposureLevel to em-dash placeholder")
    func initialExposureLevel() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.exposureLevel == "—")
    }

    @Test("ViewModel initialises framesPerSecond to 0")
    func initialFramesPerSecond() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.framesPerSecond == 0)
    }

    @Test("ViewModel initialises thermalState to nominal")
    func initialThermalState() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.thermalState == "nominal")
    }

    @Test("ViewModel initialises dropCount to 0")
    func initialDropCount() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.dropCount == 0)
    }

    @Test("ViewModel initialises meanFrameMs to 0.0")
    func initialMeanFrameMs() {
        let viewModel = DebugOverlayViewModel()
        #expect(viewModel.meanFrameMs == 0.0)
    }

    // MARK: - Published property mutation

    @Test("Assigning tiltDegrees reflects the new value")
    func updateTiltDegrees() {
        let viewModel = DebugOverlayViewModel()
        viewModel.tiltDegrees = 45.0
        #expect(viewModel.tiltDegrees == 45.0)
    }

    @Test("Assigning blurScore reflects the new value")
    func updateBlurScore() {
        let viewModel = DebugOverlayViewModel()
        viewModel.blurScore = 0.75
        #expect(viewModel.blurScore == 0.75)
    }

    @Test("Assigning exposureLevel reflects the new value")
    func updateExposureLevel() {
        let viewModel = DebugOverlayViewModel()
        viewModel.exposureLevel = "bright"
        #expect(viewModel.exposureLevel == "bright")
    }

    @Test("Assigning framesPerSecond reflects the new value")
    func updateFramesPerSecond() {
        let viewModel = DebugOverlayViewModel()
        viewModel.framesPerSecond = 30.0
        #expect(viewModel.framesPerSecond == 30.0)
    }

    @Test("Assigning thermalState reflects the new value")
    func updateThermalState() {
        let viewModel = DebugOverlayViewModel()
        viewModel.thermalState = "serious"
        #expect(viewModel.thermalState == "serious")
    }

    @Test("Assigning dropCount reflects the new value")
    func updateDropCount() {
        let viewModel = DebugOverlayViewModel()
        viewModel.dropCount = 7
        #expect(viewModel.dropCount == 7)
    }

    @Test("Assigning meanFrameMs reflects the new value")
    func updateMeanFrameMs() {
        let viewModel = DebugOverlayViewModel()
        viewModel.meanFrameMs = 12.5
        #expect(viewModel.meanFrameMs == 12.5)
    }
}
