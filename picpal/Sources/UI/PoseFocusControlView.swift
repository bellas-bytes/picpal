import SwiftUI

/// Groups refer to independently measurable details; absent members stay unknown.
enum PoseFocus: String, CaseIterable, Identifiable {
    case all, hand, head, shoulders
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All visible details"
        case .hand: "Hand"
        case .head: "Head"
        case .shoulders: "Shoulders"
        }
    }
    var details: Set<PoseDetailKey> {
        switch self {
        case .all: Set(PoseDetailKey.allCases)
        case .hand: [.handPosition, .fingerSpread, .handRoll]
        case .head: [.headTilt, .headTurn]
        case .shoulders: [.shoulderTilt]
        }
    }
}

struct PoseFocusControlView: View {
    @ObservedObject var session: ReferenceSession
    var onChange: () -> Void

    var body: some View {
        if !session.availablePoseDetails.isEmpty {
            Menu {
                ForEach(PoseFocus.allCases.filter {
                    $0 == .all || !session.availablePoseDetails.isDisjoint(with: $0.details)
                }) { focus in
                    Button {
                        if session.setPoseFocus(focus) { onChange() }
                    } label: {
                        if session.poseFocus == focus {
                            Label(focus.title, systemImage: "checkmark")
                        } else {
                            Text(focus.title)
                        }
                    }
                }
            } label: {
                Label("Focus: \(session.poseFocus.title)", systemImage: "scope")
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
            }
            .accessibilityIdentifier("poseFocusSelector")
            .accessibilityHint("Choose which visible reference pose details to coach")
        }
    }
}
