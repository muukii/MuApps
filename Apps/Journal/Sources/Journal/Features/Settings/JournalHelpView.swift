import MuColor
import SwiftUI

/// Settings detail screen for practical Journal support topics.
///
/// This is intentionally guidance-only. Destructive CloudKit actions stay in
/// the existing vault flows until a dedicated erase-all design is reviewed.
struct JournalHelpView: View {

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        JournalHelpHeroView()

        VStack(spacing: 12) {
          ForEach(JournalHelpContent.topics) { topic in
            JournalHelpTopicCard(topic: topic)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
    }
    .background(.background)
    .navigationTitle("Help")
    .journalInlineNavigationTitle()
  }
}

// MARK: - Content

/// Static help copy for common Journal data and account questions.
fileprivate enum JournalHelpContent {

  static let introduction: LocalizedStringResource =
    "Quick answers for sync, storage, deletion, widgets, and privacy."

  static var topics: [JournalHelpTopic] {
    var topics = [
      JournalHelpTopic(
        id: "icloud-sync",
        title: "iCloud Sync",
        symbolName: "icloud",
        summary: "Tinycurve stores vaults locally and syncs them with Apple's CloudKit when iCloud is available.",
        points: [
          JournalHelpPoint(
            id: "local-first",
            title: "Local first",
            body: "Cards and media are saved on this device first, then synced through the vault's CloudKit zone."
          ),
          JournalHelpPoint(
            id: "no-developer-server",
            title: "No journal server",
            body: "The developer does not run a separate server that receives your journal content."
          ),
        ]
      ),
      JournalHelpTopic(
        id: "deleting-data",
        title: "Deleting Data",
        symbolName: "trash",
        summary: "Delete owned vaults from Tinycurve when you want to remove the CloudKit data your Apple Account owns.",
        points: [
          JournalHelpPoint(
            id: "owned-vault",
            title: "Owned vaults",
            body: "Deleting an owned vault removes its CloudKit zone before local files, so everyone with access loses that vault."
          ),
          JournalHelpPoint(
            id: "shared-vault",
            title: "Shared vaults",
            body: "Deleting a vault shared with you removes it from your account. The owner controls whether the source vault is deleted."
          ),
          JournalHelpPoint(
            id: "app-delete",
            title: "Deleting the app",
            body: "Removing Tinycurve from a device removes local files from that device, but it is not the same as deleting CloudKit data."
          ),
        ]
      ),
      JournalHelpTopic(
        id: "storage",
        title: "Cloud Storage",
        symbolName: "externaldrive.badge.icloud",
        summary: "The Cloud Storage screen estimates how much Journal payload is stored through CloudKit.",
        points: [
          JournalHelpPoint(
            id: "estimate",
            title: "Estimate only",
            body: "CloudKit does not expose exact iCloud quota usage to apps, so Tinycurve calculates from local vault records and attachment sizes."
          ),
          JournalHelpPoint(
            id: "quota-owner",
            title: "Storage owner",
            body: "Owned vaults count toward your iCloud storage. Shared vaults are charged to the originating owner's iCloud storage."
          ),
        ]
      ),
      JournalHelpTopic(
        id: "widgets",
        title: "Widgets",
        symbolName: "square.grid.2x2",
        summary: "Widgets read the vault you choose and render the latest card locally.",
        points: [
          JournalHelpPoint(
            id: "vault-choice",
            title: "Choose a vault",
            body: "Edit the widget configuration to choose which vault appears on the Home Screen, Lock Screen, or StandBy."
          ),
          JournalHelpPoint(
            id: "local-render",
            title: "Local rendering",
            body: "Widget timelines are generated from the app group storage on this device."
          ),
        ]
      ),
      JournalHelpTopic(
        id: "privacy",
        title: "Privacy",
        symbolName: "hand.raised",
        summary: "Tinycurve asks for device permissions only when a feature needs them.",
        points: [
          JournalHelpPoint(
            id: "permissions",
            title: "Optional permissions",
            body: "Camera, microphone, Photos, location, and Journaling Suggestions are used only for the cards you choose to create."
          ),
          JournalHelpPoint(
            id: "policy",
            title: "Policy details",
            body: "The Privacy Policy page has the full data handling summary."
          ),
        ]
      ),
    ]

    #if DEBUG
    topics.append(
      JournalHelpTopic(
        id: "developer-builds",
        title: "Developer Builds",
        symbolName: "hammer",
        summary: "Debug builds use CloudKit Development. TestFlight and App Store builds use CloudKit Production.",
        points: [
          JournalHelpPoint(
            id: "separate-environments",
            title: "Separate data",
            body: "Development and production have separate local vault stores, sync state, and CloudKit records."
          ),
          JournalHelpPoint(
            id: "production-delete",
            title: "Production deletion",
            body: "To delete production CloudKit data, run the deletion flow from a production build or CloudKit Console production data."
          ),
        ]
      )
    )
    #endif

    return topics
  }
}

/// One help topic card shown on the Help screen.
fileprivate struct JournalHelpTopic: Identifiable {

  let id: String
  let title: LocalizedStringResource
  let symbolName: String
  let summary: LocalizedStringResource
  let points: [JournalHelpPoint]
}

/// A short actionable note inside one help topic.
fileprivate struct JournalHelpPoint: Identifiable {

  let id: String
  let title: LocalizedStringResource
  let body: LocalizedStringResource
}

// MARK: - Fileprivate Views

/// Header copy for the Help screen.
fileprivate struct JournalHelpHeroView: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "questionmark.circle.fill")
        .font(.largeTitle)
        .foregroundStyle(.tint)

      Text("Help")
        .font(.largeTitle.bold())

      Text(JournalHelpContent.introduction)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.appSecondaryContainer)
    )
  }
}

/// A compact card for one support topic.
fileprivate struct JournalHelpTopicCard: View {

  let topic: JournalHelpTopic

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      JournalHelpTopicHeader(topic: topic)

      VStack(alignment: .leading, spacing: 12) {
        ForEach(topic.points) { point in
          JournalHelpPointRow(point: point)
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(.appSecondaryContainer)
    )
  }
}

/// Icon, title, and one-sentence summary for a help topic.
fileprivate struct JournalHelpTopicHeader: View {

  let topic: JournalHelpTopic

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: topic.symbolName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.appOnTint)
        .frame(width: 30, height: 30)
        .background(Circle().fill(.tint))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(topic.title)
          .font(.headline)
          .foregroundStyle(.primary)

        Text(topic.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// One short answer inside a topic card.
fileprivate struct JournalHelpPointRow: View {

  let point: JournalHelpPoint

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(point.title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)

      Text(point.body)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, 42)
  }
}

#Preview {
  NavigationStack {
    JournalHelpView()
  }
  .environment(\.appPalette, .default)
}
