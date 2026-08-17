import SwiftUI

// MARK: - ConsentLayout

/// Layout constants for `ConsentSheet`.
///
/// All numeric values are defined here — no bare literals appear in the view.
private enum ConsentLayout {
    static let iconSize: CGFloat = 80
    static let sectionSpacing: CGFloat = 24
    static let outerPadding: CGFloat = 24
    static let buttonHeight: CGFloat = 50
    static let buttonCornerRadius: CGFloat = 12
}

// MARK: - ConsentSheet

/// Full-screen consent modal shown on first launch.
///
/// Presents the privacy disclosure and requires the user to make an explicit
/// choice. Swipe-down dismissal is disabled — the user **must** tap one of the
/// two action buttons. The choice is recorded by calling `onConsent`.
///
/// Presentation is driven by the caller (e.g. `ContentView`) via
/// `.fullScreenCover(isPresented:)`. The view itself never triggers dismissal;
/// the `onConsent` callback is the only exit path.
struct ConsentSheet: View {

    // MARK: - Properties

    /// Called when the user makes a choice.
    ///
    /// - Parameter `Bool`: `true` if the user enabled cloud coaching; `false`
    ///   to stay on-device only.
    let onConsent: (Bool) -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: ConsentLayout.sectionSpacing) {
            iconSection
            titleSection
            disclosureSection
            Spacer()
            buttonStack
        }
        .interactiveDismissDisabled(true)
        .padding(ConsentLayout.outerPadding)
    }

    // MARK: - Sections

    private var iconSection: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(
                    width: ConsentLayout.iconSize,
                    height: ConsentLayout.iconSize
                )
            Image(systemName: "camera.viewfinder")
                .imageScale(.large)
                .font(.system(size: ConsentLayout.iconSize * 0.4))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.top, ConsentLayout.sectionSpacing)
    }

    private var titleSection: some View {
        Text("PicPal Composition Coach")
            .font(.title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)
    }

    private var disclosureSection: some View {
        ScrollView {
            Text(VLMPrivacyDisclosure.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var buttonStack: some View {
        VStack(spacing: ConsentLayout.sectionSpacing / 2) {
            cloudButton
            onDeviceButton
        }
    }

    private var cloudButton: some View {
        Button {
            onConsent(true)
        } label: {
            Text("Enable cloud coaching")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: ConsentLayout.buttonHeight)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(
                    RoundedRectangle(cornerRadius: ConsentLayout.buttonCornerRadius)
                )
        }
    }

    private var onDeviceButton: some View {
        Button {
            onConsent(false)
        } label: {
            Text("Stay on-device only")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: ConsentLayout.buttonHeight)
                .foregroundStyle(Color.accentColor)
        }
    }
}
