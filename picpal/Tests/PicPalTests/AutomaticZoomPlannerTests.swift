import CoreGraphics
import Testing
@testable import PicPal

struct AutomaticZoomPlannerTests {
    @Test func centeredSubjectGetsConservativeZoom() {
        let result = AutomaticZoomPlanner.target(current: 1, minZoom: 1, maxZoom: 5,
            box: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5), style: .fullBody)
        #expect(abs(result - 1.44) < 0.0001)
    }

    @Test func highSubjectKeepsHeadMargin() {
        let box = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.5)
        let zoom = AutomaticZoomPlanner.target(current: 1, minZoom: 1, maxZoom: 5, box: box, style: .fullBody)
        let projectedTop = 0.5 + (box.maxY - 0.5) * zoom
        #expect(projectedTop <= 0.965)
        #expect(zoom < 1.44)
    }

    @Test func offCenterSubjectKeepsSideMargin() {
        let box = CGRect(x: 0.59, y: 0.25, width: 0.3, height: 0.5)
        let zoom = AutomaticZoomPlanner.target(current: 1, minZoom: 1, maxZoom: 5, box: box, style: .fullBody)
        #expect(0.5 + (box.maxX - 0.5) * zoom <= 0.975)
        #expect(0.5 + (box.midX - 0.5) * zoom <= 0.75)
    }

    @Test func fullBodyKeepsFeetButPortraitAllowsLowerCrop() {
        let box = CGRect(x: 0.35, y: 0, width: 0.3, height: 0.65)
        let full = AutomaticZoomPlanner.target(current: 1, minZoom: 0.5, maxZoom: 5, box: box, style: .fullBody)
        let portrait = AutomaticZoomPlanner.target(current: 1, minZoom: 0.5, maxZoom: 5, box: box, style: .portrait)
        #expect(0.5 + (box.minY - 0.5) * full >= 0.035)
        #expect(portrait > 1)
    }

    @Test func respectsHardwareAndQualityCeiling() {
        let box = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        #expect(AutomaticZoomPlanner.target(current: 1, minZoom: 1, maxZoom: 1.5, box: box, style: .portrait) == 1.5)
        #expect(AutomaticZoomPlanner.target(current: 1, minZoom: 1, maxZoom: 10, box: box, style: .portrait) == 2)
    }

    @Test func invalidInputsHoldCurrentZoom() {
        #expect(AutomaticZoomPlanner.target(current: 1.3, minZoom: 1, maxZoom: 5, box: .zero, style: .portrait) == 1.3)
        #expect(AutomaticZoomPlanner.target(current: 1.3, minZoom: 1, maxZoom: 5,
            box: CGRect(x: CGFloat.nan, y: 0, width: 0.2, height: 0.5), style: .portrait) == 1.3)
    }
}
