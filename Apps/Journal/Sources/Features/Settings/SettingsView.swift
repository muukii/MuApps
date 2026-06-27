import MuColor
import SwiftUI
import CaptureAudio
import CaptureBlob
import CapturePhoto
import CaptureSuggestions
import CaptureText
import JournalModel
import MuColor
import MuHaptics
import SwiftData
import SwiftUI

/// App-wide `UserDefaults` keys for Journal.
enum JournalDefaults {
  /// Selected color theme id. Resolved against `Theme.all` via `Theme.with(id:)`,
  /// falling back to `Theme.default` for unknown ids.
  static let themeID = "journal.theme.id"

  /// Whether the first-run onboarding has been completed. While `false`,
  /// `RootView` shows `OnboardingView` instead of the main app.
  static let hasCompletedOnboarding = "journal.onboarding.completed"
}

struct SettingsScreen: View {
  
  var body: some View {
    NavigationStack {
      SettingsView()
    }
  }
}

struct SettingsView: View {

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id

  /// Drives the manual re-showing of onboarding from this screen. Unlike the
  /// first-run path, this presents over the app and dismisses on completion —
  /// it never touches `hasCompletedOnboarding`.
  @State private var isShowingOnboarding = false

  var body: some View {
    Form {
      Section {
        SyncStatusRow(summary: SyncStatusMonitor.shared.summary)
      } header: {
        Text("iCloud Sync")
      } footer: {
        Text("Notes sync automatically across devices signed in to the same iCloud account.")
      }

      Section {
        ForEach(Theme.all) { theme in
          ThemeRow(
            theme: theme,
            isSelected: theme.id == themeID,
            onSelect: {
              withAnimation(.spring) {
                themeID = theme.id
              }
            }
          )
        }
      } header: {
        Text("Theme")
      } footer: {
        Text("Applies the color palette across the app.")
      }
      
      Section("Capture") {
        NavigationLink {
          TextCaptureDemoView()
        } label: {
          Label("Text", systemImage: "text.alignleft")
        }

        NavigationLink {
          PhotoCaptureDemoView()
        } label: {
          Label("Photo", systemImage: "camera")
        }

        NavigationLink {
          DoodleCaptureView()
        } label: {
          Label("Doodle", systemImage: "scribble.variable")
        }

        NavigationLink {
          BlobCaptureDemoView()
        } label: {
          Label("Blob Paint", systemImage: "paintbrush.pointed")
        }

        NavigationLink {
          AudioCaptureDemoView()
        } label: {
          Label("Ambient Sound", systemImage: "waveform")
        }

        NavigationLink {
          SuggestionCaptureDemoView()
        } label: {
          Label("Suggestions", systemImage: "sparkles")
        }
      }

      Section("Lab") {
        NavigationLink {
          HapticEditorView()
        } label: {
          Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
        }
      }

      Section("About") {
        Button {
          isShowingOnboarding = true
        } label: {
          Label("Show Onboarding", systemImage: "sparkles")
        }
      }
    }
//    .listRowBackground(Rectangle().fill(.appSecondaryContainer))
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.selection, trigger: themeID)
    .fullScreenCover(isPresented: $isShowingOnboarding) {
      OnboardingView(onComplete: { isShowingOnboarding = false })
    }
  }
}

// MARK: - Fileprivate Views

fileprivate struct ThemeRow: View {

  @Environment(\.colorScheme) private var colorScheme

  let theme: Theme
  let isSelected: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        ThemeSwatch(palette: theme.palette(for: colorScheme))

        Text(theme.name)
          .foregroundStyle(.primary)

        Spacer(minLength: 0)

        if isSelected {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(.tint)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A compact preview of a palette: the primary surface with tint and secondary
/// dots, so each theme is recognizable by color rather than name alone.
fileprivate struct ThemeSwatch: View {

  let palette: Palette

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(palette.primaryContainer)

      HStack(spacing: 4) {
        Circle().fill(palette.tint)
        Circle().fill(palette.secondaryContainer)
      }
      .frame(height: 14)
      .padding(8)
    }
    .frame(width: 56, height: 36)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(palette.outline)
    )
  }
}

/// Renders the coarse `SyncStatusMonitor.Summary` as an icon + label. Presentation
/// (symbol, color, copy) lives here; the monitor only owns state.
fileprivate struct SyncStatusRow: View {

  let summary: SyncStatusMonitor.Summary

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(iconStyle)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)

      if isSyncing {
        ProgressView()
      }
    }
  }

  private var isSyncing: Bool {
    if case .syncing = summary { return true }
    return false
  }

  private var symbol: String {
    switch summary {
    case .checking: "icloud"
    case .accountUnavailable: "lock.icloud"
    case .syncing: "arrow.clockwise.icloud"
    case .failed: "exclamationmark.icloud"
    case .idle: "checkmark.icloud"
    }
  }

  private var iconStyle: AnyShapeStyle {
    switch summary {
    case .checking, .accountUnavailable: AnyShapeStyle(.secondary)
    case .syncing: AnyShapeStyle(.tint)
    case .failed: AnyShapeStyle(.red)
    case .idle: AnyShapeStyle(.green)
    }
  }

  private var title: String {
    switch summary {
    case .checking: "Checking iCloud…"
    case .accountUnavailable(let reason): reason
    case .syncing(let label): label
    case .failed: "Sync error"
    case .idle: "Synced"
    }
  }

  private var detail: String? {
    switch summary {
    case .checking, .syncing:
      return nil
    case .accountUnavailable:
      return "Sign in to iCloud in the Settings app to sync."
    case .failed(let message):
      return message
    case .idle(let lastSyncedAt):
      guard let lastSyncedAt else { return "iCloud sync is on." }
      return "Last synced \(lastSyncedAt.formatted(.relative(presentation: .named)))."
    }
  }
}

// MARK: - Previews

#Preview {
  NavigationStack {
    SettingsView()
  }
}
