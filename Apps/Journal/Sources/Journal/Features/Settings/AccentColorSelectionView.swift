import MuColor
import SwiftUI

/// Selects the single key color used by interactive Journal chrome.
struct AccentColorSelectionView: View {

  @AppStorage(JournalDefaults.accentColorID)
  private var accentColorID: String = AccentColor.default.id

  var body: some View {
    Form {
      Section {
        ForEach(AccentColor.all) { accentColor in
          AccentColorPickerRow(
            accentColor: accentColor,
            isSelected: accentColor.id == AccentColor.with(id: accentColorID).id,
            onSelect: {
              withAnimation(.spring) {
                accentColorID = accentColor.id
              }
            }
          )
        }
      } header: {
        Text("Key accent color")
      } footer: {
        Text("Accent marks selection, focus, and primary actions. Your content keeps its own color.")
      }
    }
    .navigationTitle("Accent Color")
    .appInlineNavigationTitle()
    .sensoryFeedback(.selection, trigger: accentColorID)
  }
}

// MARK: - Fileprivate Views

/// A picker row that previews an accent without tinting its neutral surface.
fileprivate struct AccentColorPickerRow: View {

  @Environment(\.colorScheme) private var colorScheme

  let accentColor: AccentColor
  let isSelected: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    let palette = Palette(accentColor: accentColor, colorScheme: colorScheme)

    Button(action: onSelect) {
      HStack(spacing: 12) {
        Circle()
          .fill(palette.tint)
          .frame(width: 28, height: 28)
          .overlay {
            Circle().strokeBorder(palette.outline)
          }

        Text(accentColor.name)
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

#Preview {
  NavigationStack {
    AccentColorSelectionView()
  }
}
