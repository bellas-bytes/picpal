import Foundation
import CoreImage
import CoreVideo
import Testing
import UIKit
import Vision
@testable import PicPal

struct ReferenceBodyTrackerTests {
    @Test func mapsAnatomicalJointsAndConvertsYAxis() {
        let points = (0..<33).map { index in
            BodyTrackerLandmark(x: Float(index) / 100 + 0.1, y: 0.3, visibility: 0.9, presence: 0.8)
        }
        let result = ReferenceBodyTracker.adapt([points])
        let names: [(Int, VNHumanBodyPoseObservation.JointName)] = [(11, .leftShoulder), (12, .rightShoulder),
            (13, .leftElbow), (14, .rightElbow), (15, .leftWrist), (16, .rightWrist),
            (23, .leftHip), (24, .rightHip), (25, .leftKnee), (26, .rightKnee), (27, .leftAnkle), (28, .rightAnkle)]
        #expect(result.subjectCount == 1)
        for (index, name) in names {
            let joint = result.joints[name.rawValue.rawValue]
            #expect(abs((joint?.point.x ?? -1) - CGFloat(Float(index) / 100 + 0.1)) < 0.0001)
            #expect(abs((joint?.point.y ?? -1) - 0.7) < 0.0001)
            #expect(joint?.confidence == 0.8)
        }
    }

    @Test func missingOccludedMalformedAndMultiplePeopleNeverSupplyJoints() {
        let good = BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: 0.9, presence: 0.9)
        for bad in [BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: nil, presence: 0.9),
                    BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: 0.9, presence: nil),
                    BodyTrackerLandmark(x: .nan, y: 0.4, visibility: 0.9, presence: 0.9),
                    BodyTrackerLandmark(x: 1.1, y: 0.4, visibility: 0.9, presence: 0.9),
                    BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: 0.2, presence: 0.9),
                    BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: .nan, presence: 0.9)] {
            var points = Array(repeating: good, count: 33)
            points[15] = bad
            #expect(ReferenceBodyTracker.adapt([points]).joints[VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue] == nil)
        }
        #expect(ReferenceBodyTracker.adapt([[good]]).joints.isEmpty)
        let points = Array(repeating: good, count: 33)
        let multiple = ReferenceBodyTracker.adapt([points, points])
        #expect(multiple.subjectCount == 2)
        #expect(multiple.joints.isEmpty)
    }

    @Test func mirroredLivePixelsAreUnmirroredBeforeInferenceAndMappedBackWithoutSwappingJoints() throws {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
            .composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2)))
        let context = CIContext()
        for mirrored in [false, true] {
            let image = ReferenceBodyTracker.canonicalVideoImage(source, isMirrored: mirrored)
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            #expect(pixel[mirrored ? 2 : 0] > 240)
            #expect(pixel[mirrored ? 0 : 2] < 15)
            let key = VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue
            let result = BodyTrackerResult(joints: [key: LivePoseJoint(point: CGPoint(x: 0.2, y: 0.7), confidence: 0.9)], subjectCount: 1)
                .displayed(isMirrored: mirrored)
            #expect(abs((result.joints[key]?.point.x ?? -1) - (mirrored ? 0.8 : 0.2)) < 0.0001)
            #expect(result.joints[key]?.point.y == 0.7)
            #expect(result.joints[key]?.confidence == 0.9)
        }
    }

    @Test func associationRequiresOnePersonAndAllTorsoJointsInsideTheirBox() {
        let points = Array(repeating: BodyTrackerLandmark(x: 0.4, y: 0.4, visibility: 0.9, presence: 0.9), count: 33)
        let result = ReferenceBodyTracker.adapt([points])
        let box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        #expect(result.associatedJoints(personBoxes: [box]).count == 12)
        #expect(result.associatedJoints(personBoxes: [box, box]).isEmpty)
        #expect(result.associatedJoints(personBoxes: [CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1)]).isEmpty)
    }

    @Test func referenceOrientationIsBakedUprightIncludingMirrors() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        let cg = try #require(source.cgImage)
        for orientation: UIImage.Orientation in [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            let oriented = UIImage(cgImage: cg, scale: source.scale, orientation: orientation)
            let baked = ReferenceBodyTracker.uprightImage(oriented)
            #expect(baked.imageOrientation == .up)
            #expect(baked.size == oriented.size)
            #expect(baked.cgImage != nil)
        }
    }

    @Test func realBundledModelInitializesAndInfersBlankImageAndVideo() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        let tracker = try ReferenceBodyTracker(video: false)
        #expect(try tracker.detect(image: image).subjectCount == 0)
        let video = try ReferenceBodyTracker(video: true)
        #expect(try video.detectVideo(image: image, timestampMilliseconds: 100).subjectCount == 0)
        #expect(try video.detectVideo(image: image, timestampMilliseconds: 99).subjectCount == 0)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 128, 128,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CIContext().render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128)), to: buffer)
        #expect(try video.detectVideo(pixelBuffer: buffer, timestampMilliseconds: 101).subjectCount == 0)
    }
}
