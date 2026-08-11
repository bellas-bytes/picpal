import SwiftUI

struct PostSessionSurveySheet: View {
    let onResponse: (Int?) -> Void   // nil = skipped

    var body: some View {
        VStack(spacing: SurveyLayout.sectionSpacing) {
            Text("Quick check")
                .font(.headline)
            Text("Did the coaching cues come fast enough to act on?")
                .font(.body)
                .multilineTextAlignment(.center)

            // Five response buttons stacked vertically
            ForEach(PostSessionSurvey.minResponse...PostSessionSurvey.maxResponse, id: \.self) { value in
                Button(SurveyLayout.labels[value - 1]) {
                    onResponse(value)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }

            Button("Skip") {
                onResponse(nil)
            }
            .foregroundStyle(.secondary)
        }
        .padding(SurveyLayout.outerPadding)
        .presentationDetents([.medium])
    }
}

private enum SurveyLayout {
    static let labels: [String] = ["Never", "Rarely", "Sometimes", "Often", "Always"]
    static let sectionSpacing: CGFloat = 16
    static let outerPadding: CGFloat = 24
}
