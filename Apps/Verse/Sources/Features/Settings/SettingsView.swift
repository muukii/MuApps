//
//  SettingsView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/04.
//

import AppIntents
import SwiftUI

enum Settings {
  // MARK: - Main View

  struct View: SwiftUI.View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VideoItemService.self) private var historyService
    @State private var explanationService = ExplanationService()
    @State private var foundationModelService = FoundationModelService()
    @State private var showClearHistoryConfirmation = false

    var body: some SwiftUI.View {
      NavigationStack {
        List {
          appleIntelligenceSection
          transcriptionSection
          siriAndShortcutsSection
          dataManagementSection
          debugSection
          experimentalFeaturesSection
        }
        .navigationTitle("Settings")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              dismiss()
            }
          }
        }
        .confirmationDialog(
          "Clear History",
          isPresented: $showClearHistoryConfirmation,
          titleVisibility: .visible
        ) {
          Button("Clear All History", role: .destructive) {
            Task {
              try? await historyService.clearAllHistory()
            }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Are you sure you want to clear all history? This will remove all watched videos and cannot be undone.")
        }
      }
    }

    // MARK: - Sections

    private var appleIntelligenceSection: some SwiftUI.View {
      Section {
        AppleIntelligenceStatusRow(
          explanationService: explanationService,
          foundationModelService: foundationModelService
        )
      } header: {
        Text("Apple Intelligence")
      } footer: {
        AppleIntelligenceFooter(
          explanationService: explanationService,
          foundationModelService: foundationModelService
        )
      }
    }

    private var transcriptionSection: some SwiftUI.View {
      Section {
        AutoTranscribeToggle()
      } header: {
        Text("Transcription")
      } footer: {
        Text("Automatically generate subtitles from video audio when cached subtitles are missing or don't include word timing.")
      }
    }

    private var siriAndShortcutsSection: some SwiftUI.View {
      Group {
        Section {
          SiriTipView(intent: OpenYouTubeVideoIntent())
        } header: {
          Text("Siri")
        } footer: {
          Text("Use Siri to quickly open YouTube videos with subtitles.")
        }

        Section {
          ShortcutsLink()
            .shortcutsLinkStyle(.automaticOutline)
        } header: {
          Text("Shortcuts")
        } footer: {
          Text("Create custom shortcuts with the Shortcuts app.")
        }
      }
    }

    @ViewBuilder
    private var dataManagementSection: some SwiftUI.View {
      DataManagementSection(showClearHistoryConfirmation: $showClearHistoryConfirmation)
    }

    @ViewBuilder
    private var debugSection: some SwiftUI.View {
      #if DEBUG
        FeatureFlagsSettingsView()
      #endif
    }

    @ViewBuilder
    private var experimentalFeaturesSection: some SwiftUI.View {
      ExperimentalFeaturesSection()
    }
  }

  // MARK: - Apple Intelligence Components

  struct AppleIntelligenceStatusRow: SwiftUI.View {
    let explanationService: ExplanationService
    let foundationModelService: FoundationModelService

    var body: some SwiftUI.View {
      VStack(alignment: .leading, spacing: 12) {
        // Word Explanations
        HStack {
          Label {
            Text("Word Explanations")
          } icon: {
            Image(systemName: "text.bubble")
              .foregroundStyle(.blue)
          }

          Spacer()

          statusBadge(for: explanationService)
        }

        // Vocabulary Auto-Fill
        HStack {
          Label {
            Text("Vocabulary Auto-Fill")
          } icon: {
            Image(systemName: "text.book.closed")
              .foregroundStyle(.purple)
          }

          Spacer()

          statusBadge(for: foundationModelService)
        }
      }
      .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for service: ExplanationService) -> some SwiftUI.View {
      let availability = service.checkAvailability()

      switch availability {
      case .available:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Available")
            .foregroundStyle(.secondary)
        }
        .font(.caption)

      case .unavailable(let reason):
        HStack(spacing: 4) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.orange)
          Text(statusText(for: reason))
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
    }

    @ViewBuilder
    private func statusBadge(for service: FoundationModelService) -> some SwiftUI.View {
      let availability = service.checkAvailability()

      switch availability {
      case .available:
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("Available")
            .foregroundStyle(.secondary)
        }
        .font(.caption)

      case .unavailable:
        HStack(spacing: 4) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.orange)
          Text("Unavailable")
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
    }

    private func statusText(for reason: ExplanationService.Availability.UnavailabilityReason) -> String {
      switch reason {
      case .deviceNotEligible:
        return "Not Supported"
      case .appleIntelligenceNotEnabled:
        return "Enable in Settings"
      case .modelNotReady:
        return "Downloading..."
      case .unknown:
        return "Unavailable"
      }
    }
  }

  struct AppleIntelligenceFooter: SwiftUI.View {
    let explanationService: ExplanationService
    let foundationModelService: FoundationModelService

    var body: some SwiftUI.View {
      let explanationAvailability = explanationService.checkAvailability()
      let vocabularyAvailability = foundationModelService.checkAvailability()

      VStack(alignment: .leading, spacing: 8) {
        // Overall status
        switch (explanationAvailability, vocabularyAvailability) {
        case (.available, .available):
          Text("Apple Intelligence is ready to use for word explanations and vocabulary auto-fill.")

        case (.available, .unavailable):
          Text("Apple Intelligence is ready for word explanations. Vocabulary auto-fill is not available.")

        case (.unavailable, .available):
          Text("Apple Intelligence is ready for vocabulary auto-fill. Word explanations are not available.")

        case (.unavailable(let reason), .unavailable):
          detailedUnavailableMessage(for: reason)
        }
      }
    }

    @ViewBuilder
    private func detailedUnavailableMessage(for reason: ExplanationService.Availability.UnavailabilityReason) -> some SwiftUI.View {
      switch reason {
      case .deviceNotEligible:
        Text("This device does not support Apple Intelligence. These features require a compatible device.")
      case .appleIntelligenceNotEnabled:
        Text("Enable Apple Intelligence in System Settings > Apple Intelligence & Siri to use these features.")
      case .modelNotReady:
        Text("Apple Intelligence model is being downloaded by the system. Features will be available when ready.")
      case .unknown:
        Text("Apple Intelligence is not available for these features.")
      }
    }
  }

  // MARK: - Section Components

  struct AutoTranscribeToggle: SwiftUI.View {
    @AppStorage("autoTranscribeEnabled") private var autoTranscribeEnabled: Bool = true

    var body: some SwiftUI.View {
      Toggle(isOn: $autoTranscribeEnabled) {
        Label {
          Text("Auto-Transcribe")
        } icon: {
          Image(systemName: "waveform")
            .foregroundStyle(.blue)
        }
      }
    }
  }

  struct DataManagementSection: SwiftUI.View {
    @Environment(VideoItemService.self) private var historyService
    @Binding var showClearHistoryConfirmation: Bool

    var body: some SwiftUI.View {
      Section {
        Button(role: .destructive) {
          showClearHistoryConfirmation = true
        } label: {
          Label {
            Text("Clear History")
          } icon: {
            Image(systemName: "trash")
              .foregroundStyle(.red)
          }
        }
      } header: {
        Text("Data")
      } footer: {
        Text("Remove all watched videos from history. This cannot be undone.")
      }
    }
  }

  struct ExperimentalFeaturesSection: SwiftUI.View {
    var body: some SwiftUI.View {
      Section {
        SubtitleDisplayPicker()

        NavigationLink {
          VocabularyListView()
        } label: {
          FeatureLabel(
            title: "Vocabulary",
            description: "Save and review words from subtitles",
            systemImage: "text.book.closed",
            color: .blue
          )
        }

        NavigationLink {
          PlaylistListView()
        } label: {
          FeatureLabel(
            title: "Playlists",
            description: "Organize videos into collections",
            systemImage: "list.bullet.rectangle",
            color: .orange
          )
        }

        NavigationLink {
          RealtimeTranscriptionView()
        } label: {
          FeatureLabel(
            title: "Live Transcription",
            description: "Real-time speech-to-text from microphone",
            systemImage: "waveform.badge.mic",
            color: .purple
          )
        }
      } header: {
        Text("Experimental")
      } footer: {
        Text("Features under development. Live Transcription requires iOS 26+ and physical device.")
      }
    }
  }

  struct SubtitleDisplayPicker: SwiftUI.View {
    @AppStorage("subtitleDisplayType") private var subtitleDisplayType: SubtitleDisplayType = .cellBased

    var body: some SwiftUI.View {
      Picker(selection: $subtitleDisplayType) {
        ForEach(SubtitleDisplayType.allCases) { type in
          Text(type.displayName).tag(type)
        }
      } label: {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Subtitle Display")
            Text(subtitleDisplayType == .cellBased ? "Per-cue cells with individual scrolling" : "Single continuous text view")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "text.alignleft")
            .foregroundStyle(.teal)
        }
      }
    }
  }

  // MARK: - Private Helpers

  private struct FeatureLabel: SwiftUI.View {
    let title: String
    let description: String
    let systemImage: String
    let color: Color

    var body: some SwiftUI.View {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: systemImage)
          .foregroundStyle(color)
      }
    }
  }
}

// MARK: - Type Alias

typealias SettingsView = Settings.View

// MARK: - Preview

#Preview {
  SettingsView()
}
