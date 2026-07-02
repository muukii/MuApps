import SwiftUI

/// A readable, in-app copy of Tinycurve's privacy policy.
///
/// Keep this screen aligned with `Apps/Journal/docs/PRIVACY_POLICY.md`. The
/// Markdown file is the public-policy draft; this view gives users the same
/// substance from Settings without requiring network access.
struct PrivacyPolicyView: View {

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PrivacyPolicyHeaderView()

        ForEach(PrivacyPolicyContent.sections) { section in
          PrivacyPolicySectionView(section: section)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
    }
    .background(.background)
    .navigationTitle("Privacy Policy")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - Content

/// Static policy copy shared by the section views on this screen.
fileprivate enum PrivacyPolicyContent {

  static let lastUpdated: LocalizedStringResource = "Last updated: July 2, 2026"

  static let introduction: LocalizedStringResource =
    "Tinycurve is a personal journaling app. It is designed so the developer does not run a server for your journal content and does not sell, track, or advertise with your data."

  static let sections: [PrivacyPolicySection] = [
    PrivacyPolicySection(
      id: "data-you-create",
      title: "Data you create",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "content",
          body: "When you create cards, Tinycurve can store the text you type, photos you capture, audio recordings, doodles, Bauhaus artwork, timestamps, relationships between cards, attachment metadata, and optional location coordinates."
        ),
        PrivacyPolicyParagraph(
          id: "suggestions",
          body: "If you choose a Journaling Suggestion, Apple presents the system picker. Tinycurve receives only the suggestion content you select, such as a title, date, photo reference, media metadata, workout summary, place, motion summary, contact name, or reflection prompt."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "storage-and-sync",
      title: "Storage and iCloud sync",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "local",
          body: "Your journal database and attachment files are stored on your device in Tinycurve's app container and App Group container so the app and widget can read the same entries."
        ),
        PrivacyPolicyParagraph(
          id: "icloud",
          body: "When iCloud is available, Tinycurve uses Apple's CloudKit private database to sync your cards and media across devices signed in to your Apple Account. The developer does not receive a copy of your journal content from this sync."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "permissions",
      title: "Device permissions",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "camera",
          body: "Camera access is used only when you open photo capture and take a photo for a card."
        ),
        PrivacyPolicyParagraph(
          id: "microphone",
          body: "Microphone access is used only when you record an ambient audio card."
        ),
        PrivacyPolicyParagraph(
          id: "location",
          body: "Location access is optional. When Attach Location is enabled in Settings and iOS grants permission, new cards can store the current latitude and longitude."
        ),
        PrivacyPolicyParagraph(
          id: "journaling-suggestions",
          body: "Journaling Suggestions access is used only when you open the system picker. The raw signals used by iOS to prepare suggestions stay with the system unless you select a suggestion."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "sharing-and-widgets",
      title: "Sharing and widgets",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "share",
          body: "When you use a share action, Tinycurve creates the selected image or video export on device and hands that file to the system share sheet. The destination you choose controls what happens after that."
        ),
        PrivacyPolicyParagraph(
          id: "widget",
          body: "The Tinycurve widget reads recent cards from the same on-device store. Widget content is generated locally by the widget extension."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "analytics",
      title: "Analytics, ads, and tracking",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "none",
          body: "Tinycurve does not include developer-operated analytics, advertising SDKs, third-party trackers, or cross-app tracking."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "deletion",
      title: "Deletion and retention",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "user-control",
          body: "Journal content remains until you delete it in the app, delete the app's data, or remove it through iCloud behavior controlled by Apple. iCloud sync deletion timing is governed by Apple's CloudKit and iCloud systems."
        ),
      ]
    ),
    PrivacyPolicySection(
      id: "contact",
      title: "Contact and changes",
      paragraphs: [
        PrivacyPolicyParagraph(
          id: "contact",
          body: "For privacy questions, use the developer support contact listed with Tinycurve in the App Store."
        ),
        PrivacyPolicyParagraph(
          id: "changes",
          body: "This policy may be updated as Tinycurve changes. The Last updated date shows when this copy was last revised."
        ),
      ]
    ),
  ]
}

/// One titled policy section.
fileprivate struct PrivacyPolicySection: Identifiable {

  let id: String
  let title: LocalizedStringResource
  let paragraphs: [PrivacyPolicyParagraph]
}

/// One paragraph inside a policy section.
fileprivate struct PrivacyPolicyParagraph: Identifiable {

  let id: String
  let body: LocalizedStringResource
}

// MARK: - Fileprivate Views

/// Header copy that anchors the policy date and overall stance.
fileprivate struct PrivacyPolicyHeaderView: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(PrivacyPolicyContent.lastUpdated)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Text(PrivacyPolicyContent.introduction)
        .font(.body)
        .foregroundStyle(.primary)
    }
  }
}

/// Renders a single privacy policy section with readable paragraph spacing.
fileprivate struct PrivacyPolicySectionView: View {

  let section: PrivacyPolicySection

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(section.title)
        .font(.headline)
        .foregroundStyle(.primary)

      ForEach(section.paragraphs) { paragraph in
        Text(paragraph.body)
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

#Preview {
  NavigationStack {
    PrivacyPolicyView()
  }
}
