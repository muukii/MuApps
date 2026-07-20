import MuColor
import SwiftUI

/// Settings detail screen that explains how to place Tinycurve widgets in the
/// system surfaces where the latest-note widget is available.
struct WidgetInstructionsView: View {

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        WidgetInstructionsHeroView()

        VStack(spacing: 12) {
          ForEach(WidgetInstructionContent.instructions) { instruction in
            WidgetInstructionCard(instruction: instruction)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
    }
    .background(.background)
    .navigationTitle("Widgets")
    .appInlineNavigationTitle()
  }
}

// MARK: - Content

/// Static copy for the widget installation guide.
private enum WidgetInstructionContent {

  static let introduction: LocalizedStringResource =
    "Add Tinycurve widgets for a quick view of the latest entry in a vault you choose."

  static let instructions: [WidgetInstruction] = [
    WidgetInstruction(
      id: "home-screen",
      eyebrow: "TYPE 1",
      title: "Home Screen",
      body: "Long-press the Home Screen, tap +, then add Tinycurve.",
      symbolName: "square.grid.2x2"
    ),
    WidgetInstruction(
      id: "lock-screen",
      eyebrow: "TYPE 2",
      title: "Lock Screen",
      body: "Long-press the Lock Screen, tap Customize, then add Tinycurve below the clock.",
      symbolName: "lock"
    ),
    WidgetInstruction(
      id: "standby",
      eyebrow: "TYPE 3",
      title: "StandBy",
      body: "Long-press the StandBy screen, tap +, then add Tinycurve.",
      symbolName: "iphone.landscape"
    ),
  ]
}

/// One OS surface where Tinycurve's widget can be added.
private struct WidgetInstruction: Identifiable {

  let id: String
  let eyebrow: LocalizedStringResource
  let title: LocalizedStringResource
  let body: LocalizedStringResource
  let symbolName: String
}

// MARK: - Fileprivate Views

/// Header card with a compact illustration of the widget family.
private struct WidgetInstructionsHeroView: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      WidgetHeroIllustration()

      VStack(alignment: .leading, spacing: 8) {
        Text("Widgets")
          .font(.largeTitle.bold())

        Text(WidgetInstructionContent.introduction)
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.appSecondaryContainer)
    )
  }
}

/// Decorative preview of the Home Screen and widget shapes, using the active
/// MuColor palette instead of fixed illustration colors.
private struct WidgetHeroIllustration: View {

  @Environment(\.appPalette) private var palette

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(palette.primaryContainer)

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 14) {
          WidgetPreviewStrip()
            .frame(width: 120)

          WidgetPreviewTile()
            .frame(width: 112, height: 112)
        }

        WidgetPreviewTile()
          .frame(maxWidth: .infinity)
          .frame(height: 112)
      }
      .padding(18)
    }
    .frame(height: 170)
  }
}

/// Small and medium widget previews arranged like a Home Screen row.
private struct WidgetPreviewStrip: View {

  @Environment(\.appPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(palette.secondaryContainer)
          .frame(width: 50, height: 50)
          .overlay {
            Image(systemName: "note.text")
              .font(.title3.weight(.semibold))
              .foregroundStyle(palette.tint)
          }

        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(palette.secondaryContainer)
          .frame(height: 50)
          .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 5) {
              Capsule()
                .fill(palette.tint.opacity(0.38))
                .frame(width: 36, height: 6)
              Capsule()
                .fill(palette.onSecondaryContainer.opacity(0.2))
                .frame(width: 48, height: 6)
            }
            .padding(.horizontal, 14)
          }
      }

      HStack(spacing: 6) {
        ForEach(0..<4) { index in
          Circle()
            .fill(index == 0 ? palette.tint : palette.onPrimaryContainer.opacity(0.2))
            .frame(width: 6, height: 6)
        }
      }
    }
  }
}

/// Large widget preview used to suggest the actual latest-note content.
private struct WidgetPreviewTile: View {

  @Environment(\.appPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Latest", systemImage: "note.text")
        .font(.caption.weight(.semibold))
        .foregroundStyle(palette.onSecondaryContainer.opacity(0.62))

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 6) {
        Capsule()
          .fill(palette.onSecondaryContainer.opacity(0.22))
          .frame(width: 64, height: 7)
        Capsule()
          .fill(palette.onSecondaryContainer.opacity(0.16))
          .frame(width: 84, height: 7)
        Capsule()
          .fill(palette.onSecondaryContainer.opacity(0.12))
          .frame(width: 50, height: 7)
      }

      Spacer(minLength: 0)

      Text("now")
        .font(.caption2)
        .foregroundStyle(palette.onSecondaryContainer.opacity(0.55))
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(palette.secondaryContainer)
    )
  }
}

/// One instruction card for adding the widget on a specific system surface.
private struct WidgetInstructionCard: View {

  let instruction: WidgetInstruction

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: instruction.symbolName)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.appOnTint)
          .frame(width: 28, height: 28)
          .background(Circle().fill(.tint))

        Text(instruction.eyebrow)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(instruction.title)
          .font(.title2.bold())

        Text(instruction.body)
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(.appSecondaryContainer)
    )
  }
}

#Preview {
  NavigationStack {
    WidgetInstructionsView()
  }
  .environment(\.appPalette, .default)
}
