import MuColor
import SwiftUI
import CaptureAudio
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

  var body: some View {
    Form {
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
    }
//    .listRowBackground(Rectangle().fill(.appSecondaryContainer))
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.selection, trigger: themeID)
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

// MARK: - Previews

#Preview {
  NavigationStack {
    SettingsView()
  }
}
