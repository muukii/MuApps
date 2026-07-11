import MuColor
import SwiftUI

struct ThemeSelectionView: View {

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id

  /// Vivid series themes displayed at the top, then the rest in their original order.
  private var vividThemeIDs: [String] {
    ["vermilion", "cobalt", "forest"]
  }

  private var sortedThemes: [Theme] {
    let vivid = Theme.all.filter { vividThemeIDs.contains($0.id) }
    let others = Theme.all.filter { !vividThemeIDs.contains($0.id) }
    return vivid + others
  }

  var body: some View {
    Form {
      Section {
        ForEach(sortedThemes, id: \.id) { theme in
          ThemePickerRow(
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
        Text("Choose a theme")
      } footer: {
        Text("The selected palette applies across the entire app, including Light and Dark modes.")
      }
    }
    .navigationTitle("Theme")
    .journalInlineNavigationTitle()
  }
}

// MARK: - Fileprivate Views

/// A single theme picker row.
fileprivate struct ThemePickerRow: View {

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

  @Environment(\.colorScheme) private var colorScheme
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
    ThemeSelectionView()
  }
}
