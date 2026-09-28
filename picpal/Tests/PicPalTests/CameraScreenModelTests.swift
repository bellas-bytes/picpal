import AVFoundation
import Testing
@testable import PicPal

@MainActor
struct CameraScreenModelTests {
    @Test func cameraRangeAllowsAvailableWideZoomAndUsesHardwareDisplayScale() async {
        let hardware = CameraHardwareStatus(isReady: true, zoomFactor: 0.7, minZoom: 0.5, maxZoom: 4,
            isAdjusting: false, supportsFlash: false, displayZoomMultiplier: 0.8)
        let model = CameraScreenModel(readStatus: { _ in hardware })
        await model.tick(camera: CameraCapture(), voice: VoiceCoach(), blocked: false,
            reference: nil, matchState: ReferenceMatchState())
        #expect(model.minZoom == 0.5)
        #expect(model.maxZoom == 4)
        #expect(model.zoom == 0.7)
        #expect(model.displayZoomMultiplier == 0.8)
    }

    @Test func autoSessionCanStopWhilePhotoIsSaving() async {
        let status = readyHardware
        var finishSaving: CheckedContinuation<Void, Never>?
        let model = CameraScreenModel(readStatus: { _ in status },
            takePhoto: { _, _ in Data([1]) }, writePhoto: { _ in
                await withCheckedContinuation { finishSaving = $0 }
            })
        let camera = CameraCapture()
        await model.tick(camera: camera, voice: VoiceCoach(), blocked: false,
                         reference: nil, matchState: ReferenceMatchState())
        model.toggleAutoCapture()
        model.capture(camera: camera, automatic: true)
        for _ in 0..<100 where finishSaving == nil { await Task.yield() }
        #expect(model.isArmed)
        #expect(model.isBusy)
        model.toggleAutoCapture()
        #expect(!model.isArmed)
        finishSaving?.resume()
        for _ in 0..<100 where model.isBusy { await Task.yield() }
        #expect(!model.isArmed)
        #expect(model.sessionPhotoCount == 1)
    }

    private var readyHardware: CameraHardwareStatus {
        CameraHardwareStatus(isReady: true, zoomFactor: 1, minZoom: 1, maxZoom: 2,
                             isAdjusting: false, supportsFlash: false)
    }

    @Test func failedSaveRetainsOriginalAndRetryDoesNotRecapture() async {
        let original = Data([1, 2, 3])
        var captures = 0
        var saves = 0
        let status = readyHardware
        let model = CameraScreenModel(readStatus: { _ in status }, takePhoto: { _, _ in
            captures += 1
            return original
        }, writePhoto: { data in
            #expect(data == original)
            saves += 1
            if saves == 1 { throw PhotoLibraryWriter.SaveError.permissionDenied }
        })
        let camera = CameraCapture()
        await model.tick(camera: camera, voice: VoiceCoach(), blocked: false,
                         reference: nil, matchState: ReferenceMatchState())
        model.capture(camera: camera)
        model.capture(camera: camera)
        for _ in 0..<100 where model.isBusy { await Task.yield() }
        #expect(!model.isBusy)
        #expect(captures == 1)
        #expect(model.pendingPhoto == original)
        #expect(model.errorMessage != nil)
        model.retrySave()
        for _ in 0..<100 where model.isBusy { await Task.yield() }
        #expect(model.pendingPhoto == nil)
        #expect(captures == 1)
        #expect(saves == 2)
        #expect(model.notice == "Saved to Photos")
    }

    @Test func interruptCancelsCountdownAndDisarms() async {
        var captures = 0
        let status = readyHardware
        let model = CameraScreenModel(readStatus: { _ in status }, takePhoto: { _, _ in
            captures += 1
            return Data()
        }, writePhoto: { _ in })
        let camera = CameraCapture()
        await model.tick(camera: camera, voice: VoiceCoach(), blocked: false,
                         reference: nil, matchState: ReferenceMatchState())
        model.toggleAutoCapture()
        #expect(model.isArmed)
        model.timerSeconds = 3
        model.capture(camera: camera)
        for _ in 0..<100 where model.countdown == nil { await Task.yield() }
        model.interrupt()
        for _ in 0..<100 where model.isBusy { await Task.yield() }
        #expect(!model.isBusy)
        #expect(!model.isArmed)
        #expect(captures == 0)
    }

    @Test func presentationDisarmsAndDoesNotCapture() async {
        let status = readyHardware
        let model = CameraScreenModel(readStatus: { _ in status })
        model.toggleAutoCapture()
        await model.tick(camera: CameraCapture(), voice: VoiceCoach(), blocked: true,
                         reference: nil, matchState: ReferenceMatchState())
        #expect(!model.isArmed)
        #expect(model.progress == 0)
    }
}
