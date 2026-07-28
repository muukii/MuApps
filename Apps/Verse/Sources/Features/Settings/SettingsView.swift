//
//  SettingsView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/04.
//

import SwiftUI

enum Settings {
  // MARK: - Main View

  struct View: SwiftUI.View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VideoItemService.self) private var historyService
    @State private var showClearHistoryConfirmation = false

    var body: some SwiftUI.View {
      NavigationStack {
        List {
          languageSection
          transcriptionSection
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

    private var languageSection: some SwiftUI.View {
      Section {
        ExplanationLanguagePicker()
      } header: {
        Text("Language")
      } footer: {
        Text("Language the ChatGPT prompt asks for answers in. System follows your device language.")
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

  // MARK: - Section Components

  struct ExplanationLanguagePicker: SwiftUI.View {
    @AppStorage(ExplanationLanguage.storageKey) private var language: ExplanationLanguage = .system

    var body: some SwiftUI.View {
      Picker(selection: $language) {
        ForEach(ExplanationLanguage.allCases) { language in
          Text(language.displayName).tag(language)
        }
      } label: {
        Label {
          Text("AI Response Language")
        } icon: {
          Image(systemName: "globe")
            .foregroundStyle(.green)
        }
      }
    }
  }

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
