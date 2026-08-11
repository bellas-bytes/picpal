#if DEBUG
import SwiftUI

// MARK: - SessionTaskOverlay

/// A full-screen card overlay for moderating usability sessions.
///
/// Displays the current task's number, title, and instructions. The facilitator
/// steps through tasks with Previous/Next buttons and dismisses the overlay with
/// the "Done" button once the session is complete.
///
/// Gated with `#if DEBUG` — this view is never compiled into a release build.
struct SessionTaskOverlay: View {

    let tasks: [SessionTask]
    var onDismiss: () -> Void

    @State private var currentIndex: Int = 0

    // MARK: - Body

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            taskCard
        }
    }

    // MARK: - Sub-views

    private var taskCard: some View {
        VStack(alignment: .leading, spacing: SessionTaskOverlayLayout.sectionSpacing) {
            progressLabel
            titleLabel
            instructionsLabel
            Spacer()
            navigationRow
            doneButton
        }
        .padding(SessionTaskOverlayLayout.cardPadding)
        .background(
            Color(UIColor.systemBackground),
            in: RoundedRectangle(cornerRadius: SessionTaskOverlayLayout.cardCornerRadius)
        )
        .padding(SessionTaskOverlayLayout.cardEdgeMargin)
    }

    private var progressLabel: some View {
        Text("Task \(currentIndex + 1) of \(tasks.count)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var titleLabel: some View {
        Text(currentTask.title)
            .font(.title2.bold())
    }

    private var instructionsLabel: some View {
        Text(currentTask.instructions)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var navigationRow: some View {
        HStack(spacing: SessionTaskOverlayLayout.buttonSpacing) {
            Button("Previous") {
                currentIndex -= 1
            }
            .buttonStyle(.bordered)
            .disabled(currentIndex == 0)

            Spacer()

            Button("Next") {
                currentIndex += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentIndex == tasks.count - 1)
        }
    }

    private var doneButton: some View {
        Button(action: onDismiss) {
            Text("Done")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Helpers

    private var currentTask: SessionTask {
        tasks[currentIndex]
    }
}

// MARK: - Layout constants

private enum SessionTaskOverlayLayout {
    static let cardPadding: CGFloat      = 24
    static let cardEdgeMargin: CGFloat   = 24
    static let cardCornerRadius: CGFloat = 16
    static let sectionSpacing: CGFloat   = 16
    static let buttonSpacing: CGFloat    = 12
}

// MARK: - Preview

#Preview {
    SessionTaskOverlay(tasks: SessionTaskScript.m4Tasks, onDismiss: {})
}
#endif
