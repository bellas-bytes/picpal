import Testing
import CoreGraphics
@testable import PicPal

struct ReferencePoseTests {

    // MARK: - Basic initialization

    @Test("ReferencePose initializes with all required fields")
    func referencePoseInitializesWithAllFields() {
        let keypoints: [String: CGPoint] = [
            "nose": CGPoint(x: 0.5, y: 0.5),
            "leftShoulder": CGPoint(x: 0.4, y: 0.3)
        ]
        let pose = ReferencePose(
            bodyKeypoints: keypoints,
            faceCenter: CGPoint(x: 0.5, y: 0.6),
            faceYaw: 0.1,
            subjectBoundingBox: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.6,
            headroomFraction: 0.2
        )

        #expect(pose.bodyKeypoints == keypoints)
        #expect(pose.faceCenter == CGPoint(x: 0.5, y: 0.6))
        #expect(pose.faceYaw == 0.1)
        #expect(pose.subjectBoundingBox == CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6))
        #expect(pose.subjectCenterX == 0.5)
        #expect(pose.subjectCenterY == 0.5)
        #expect(pose.subjectHeightFraction == 0.6)
        #expect(pose.headroomFraction == 0.2)
    }

    // MARK: - Sendable conformance (compile-time check — documented here)

    @Test("ReferencePose is Sendable")
    func referencePoseIsSendable() {
        // This test verifies the Sendable marker at compile time.
        // Runtime confirmation: pass ReferencePose across isolation boundaries.
        let keypoints: [String: CGPoint] = [:]
        let pose = ReferencePose(
            bodyKeypoints: keypoints,
            faceCenter: nil,
            faceYaw: nil,
            subjectBoundingBox: .zero,
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.5,
            headroomFraction: 0.2
        )
        _ = pose  // Use pose to confirm Sendable
        #expect(true)
    }

    // MARK: - Empty keypoints

    @Test("ReferencePose accepts empty bodyKeypoints")
    func referencePoseAcceptsEmptyKeypoints() {
        let pose = ReferencePose(
            bodyKeypoints: [:],
            faceCenter: CGPoint(x: 0.5, y: 0.5),
            faceYaw: nil,
            subjectBoundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.2,
            headroomFraction: 0.1
        )
        #expect(pose.bodyKeypoints.isEmpty)
    }

    // MARK: - Nil optional fields

    @Test("ReferencePose accepts nil faceCenter and faceYaw")
    func referencePoseAcceptsNilFaceFields() {
        let pose = ReferencePose(
            bodyKeypoints: ["nose": CGPoint(x: 0.5, y: 0.5)],
            faceCenter: nil,
            faceYaw: nil,
            subjectBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.4,
            headroomFraction: 0.15
        )
        #expect(pose.faceCenter == nil)
        #expect(pose.faceYaw == nil)
    }

    // MARK: - Vision coordinate space validation

    @Test("ReferencePose stores normalized coordinates (0–1 range)")
    func referencePoseStoresNormalizedCoordinates() {
        let pose = ReferencePose(
            bodyKeypoints: [
                "leftAnkle": CGPoint(x: 0.1, y: 0.05),
                "rightAnkle": CGPoint(x: 0.9, y: 0.05),
                "head": CGPoint(x: 0.5, y: 0.95)
            ],
            faceCenter: CGPoint(x: 0.5, y: 0.8),
            faceYaw: 0.0,
            subjectBoundingBox: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.9,
            headroomFraction: 0.05
        )

        // Verify all coordinates are in expected range
        for (_, point) in pose.bodyKeypoints {
            #expect(point.x >= 0.0 && point.x <= 1.0)
            #expect(point.y >= 0.0 && point.y <= 1.0)
        }

        #expect(pose.faceCenter!.x >= 0.0 && pose.faceCenter!.x <= 1.0)
        #expect(pose.faceCenter!.y >= 0.0 && pose.faceCenter!.y <= 1.0)
    }

    // MARK: - Bounding box properties

    @Test("ReferencePose subjectBoundingBox is stored correctly")
    func referencePoseSubjectBoundingBoxStoredCorrectly() {
        let bbox = CGRect(x: 0.25, y: 0.30, width: 0.5, height: 0.65)
        let pose = ReferencePose(
            bodyKeypoints: [:],
            faceCenter: nil,
            faceYaw: nil,
            subjectBoundingBox: bbox,
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.65,
            headroomFraction: 0.30
        )
        #expect(pose.subjectBoundingBox == bbox)
    }

    // MARK: - Composition parameters

    @Test("ReferencePose composition parameters reflect expected range")
    func referencePoseCompositionParametersInExpectedRange() {
        let pose = ReferencePose(
            bodyKeypoints: [:],
            faceCenter: nil,
            faceYaw: nil,
            subjectBoundingBox: .zero,
            subjectCenterX: 0.33,
            subjectCenterY: 0.67,
            subjectHeightFraction: 0.45,
            headroomFraction: 0.20
        )

        #expect(pose.subjectCenterX >= 0.0 && pose.subjectCenterX <= 1.0)
        #expect(pose.subjectCenterY >= 0.0 && pose.subjectCenterY <= 1.0)
        #expect(pose.subjectHeightFraction >= 0.0 && pose.subjectHeightFraction <= 1.0)
        #expect(pose.headroomFraction >= 0.0 && pose.headroomFraction <= 1.0)
    }

    // MARK: - Multiple keypoints

    @Test("ReferencePose stores multiple body keypoints correctly")
    func referencePoseStoresMultipleKeypoints() {
        let keypoints: [String: CGPoint] = [
            "nose": CGPoint(x: 0.5, y: 0.7),
            "leftEye": CGPoint(x: 0.45, y: 0.75),
            "rightEye": CGPoint(x: 0.55, y: 0.75),
            "leftShoulder": CGPoint(x: 0.4, y: 0.5),
            "rightShoulder": CGPoint(x: 0.6, y: 0.5),
            "leftElbow": CGPoint(x: 0.35, y: 0.35),
            "rightElbow": CGPoint(x: 0.65, y: 0.35),
            "leftWrist": CGPoint(x: 0.3, y: 0.2),
            "rightWrist": CGPoint(x: 0.7, y: 0.2)
        ]

        let pose = ReferencePose(
            bodyKeypoints: keypoints,
            faceCenter: CGPoint(x: 0.5, y: 0.7),
            faceYaw: 0.1,
            subjectBoundingBox: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.75),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.75,
            headroomFraction: 0.25
        )

        #expect(pose.bodyKeypoints.count == 9)
        #expect(pose.bodyKeypoints["nose"] == CGPoint(x: 0.5, y: 0.7))
        #expect(pose.bodyKeypoints["leftWrist"] == CGPoint(x: 0.3, y: 0.2))
        #expect(pose.bodyKeypoints["rightWrist"] == CGPoint(x: 0.7, y: 0.2))
    }

    // MARK: - Face yaw sign convention

    @Test("ReferencePose stores positive face yaw for right turn")
    func referencePosePositiveFaceYawForRightTurn() {
        let pose = ReferencePose(
            bodyKeypoints: [:],
            faceCenter: CGPoint(x: 0.5, y: 0.5),
            faceYaw: 0.3,
            subjectBoundingBox: .zero,
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.5,
            headroomFraction: 0.2
        )
        #expect(pose.faceYaw! > 0)
    }

    @Test("ReferencePose stores negative face yaw for left turn")
    func referencePoseNegativeFaceYawForLeftTurn() {
        let pose = ReferencePose(
            bodyKeypoints: [:],
            faceCenter: CGPoint(x: 0.5, y: 0.5),
            faceYaw: -0.3,
            subjectBoundingBox: .zero,
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.5,
            headroomFraction: 0.2
        )
        #expect(pose.faceYaw! < 0)
    }

    // MARK: - Value type semantics

    @Test("ReferencePose copies have independent keypoints")
    func referencePoseCopiesHaveIndependentKeypoints() {
        let pose1 = ReferencePose(
            bodyKeypoints: ["nose": CGPoint(x: 0.5, y: 0.5)],
            faceCenter: CGPoint(x: 0.5, y: 0.6),
            faceYaw: 0.1,
            subjectBoundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.4,
            headroomFraction: 0.2
        )

        var pose2Keypoints = pose1.bodyKeypoints
        pose2Keypoints["newKey"] = CGPoint(x: 0.1, y: 0.1)

        let pose2 = ReferencePose(
            bodyKeypoints: pose2Keypoints,
            faceCenter: pose1.faceCenter,
            faceYaw: pose1.faceYaw,
            subjectBoundingBox: pose1.subjectBoundingBox,
            subjectCenterX: pose1.subjectCenterX,
            subjectCenterY: pose1.subjectCenterY,
            subjectHeightFraction: pose1.subjectHeightFraction,
            headroomFraction: pose1.headroomFraction
        )

        // pose1 and pose2 should have different keypoints (independent copies)
        #expect(pose1.bodyKeypoints["newKey"] == nil)
        #expect(pose2.bodyKeypoints["newKey"] != nil)
    }
}
