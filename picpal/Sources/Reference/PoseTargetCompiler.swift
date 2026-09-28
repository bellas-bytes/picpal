import Foundation

enum PoseTargetCompiler {
    static func compile(measurements: [PoseDetailMeasurement], selected: Set<PoseDetailKey>) -> PoseTargetProfile {
        let targets = measurements.filter { selected.contains($0.key) && $0.isAvailable }.map {
            let tolerance: Double
            switch $0.key {
            case .handPosition: tolerance = 0.25
            case .headTilt, .handRoll, .shoulderTilt: tolerance = 0.15
            case .headTurn: tolerance = 0.20
            case .fingerSpread: tolerance = 0.30
            }
            return PoseTarget(measurement: $0, tolerance: tolerance, anchorLabel: nil)
        }
        return PoseTargetProfile(targets: targets, selected: selected)
    }
}
