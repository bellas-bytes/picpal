import Foundation

/// An explicitly armed photo session takes spaced shots while fresh framing is usable.
struct AutoCaptureGate {
    private(set) var isArmed = false
    private(set) var progress = 0.0
    private let holdDuration: TimeInterval
    private var readySince: TimeInterval?
    private var lastUpdate: TimeInterval?
    private var lastCapture: TimeInterval?

    init(holdDuration: TimeInterval = 0.25) {
        self.holdDuration = holdDuration.isFinite ? max(0.1, holdDuration) : 0.25
    }

    mutating func arm() {
        isArmed = true
        lastCapture = nil
        resetHold()
    }

    mutating func disarm() {
        isArmed = false
        resetHold()
    }

    mutating func update(isReady: Bool, now: TimeInterval) -> Bool {
        guard isArmed else { return false }
        guard isReady, now.isFinite else {
            resetHold()
            return false
        }
        if let lastUpdate, now < lastUpdate || now - lastUpdate > 0.8 { resetHold() }
        lastUpdate = now
        if readySince == nil { readySince = now }
        let elapsed = now - (readySince ?? now)
        progress = min(1, max(0, elapsed / holdDuration))
        guard elapsed >= holdDuration, lastCapture.map({ now - $0 >= 0.8 }) ?? true else { return false }
        lastCapture = now
        resetHold()
        return true
    }

    private mutating func resetHold() {
        readySince = nil
        lastUpdate = nil
        progress = 0
    }
}
