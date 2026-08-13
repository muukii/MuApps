import SwiftUI

/// The centerpiece: how `.backgroundStyle(_:)` actually behaves.
///
/// Three facts the demo makes tangible:
///  1. `.backgroundStyle(_:)` paints NOTHING by itself. It only writes the
///     `backgroundStyle` environment value (an `AnyShapeStyle?`).
///  2. The value is read by the `.background` ShapeStyle — e.g. `.fill(.background)`
///     or `View.background(in:)`. Those consumers are what render.
///  3. `.background.secondary` / `.tertiary` (iOS 17+) derive de-emphasised levels
///     from whatever `.background` currently resolves to.
struct BackgroundStyleDemoView: View {
  @State private var override: Color = .indigo

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {

        SectionCard(
          title: "Gotcha #1 — it paints nothing alone",
          subtitle: "Both boxes get .backgroundStyle(.indigo). Only the one with a consumer shows it."
        ) {
          HStack(spacing: 12) {
            Tile(caption: ".backgroundStyle(.indigo)\nNO consumer → empty") {
              RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.tertiary)
                .overlay {
                  Text("nothing")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .backgroundStyle(.indigo) // orphaned on purpose: no one reads it

            }
            Tile(caption: ".fill(.background)\n+ .backgroundStyle(.indigo)") {
              swatch(.background)
                .backgroundStyle(.indigo)
            }
          }
        }

        SectionCard(
          title: "It re-points the .background style",
          subtitle: "Pick an override. The same consumers below resolve to it — levels included."
        ) {
          ColorPicker("backgroundStyle override", selection: $override)
            .font(.subheadline)

          Text("Default — no .backgroundStyle (system background levels)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
          consumerRow

          Text("With .backgroundStyle(override)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
          consumerRow
            .backgroundStyle(override)
            .animation(.snappy, value: override)
        }

        SectionCard(
          title: "Layered surfaces",
          subtitle: "primary vs secondary vs tertiary is how you stack a card on a page."
        ) {
          ZStack {
            swatch(.background.secondary)
              .frame(height: 150)
            swatch(.background)
              .frame(height: 96)
              .padding(.horizontal, 28)
              .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
              .overlay {
                Text(".fill(.background) card\non a .background.secondary page")
                  .font(.system(.caption2, design: .monospaced))
                  .multilineTextAlignment(.center)
                  .foregroundStyle(.secondary)
              }
          }
        }

        SectionCard(title: "Cheat sheet", subtitle: nil) {
          VStack(alignment: .leading, spacing: 8) {
            CodeText(".backgroundStyle(.blue)            // sets env, paints nothing")
            CodeText("Shape().fill(.background)          // reads it → renders")
            CodeText(".background(in: Shape())           // reads it → renders")
            CodeText(".fill(.background.secondary)       // derived level (iOS 17+)")
          }
        }
      }
      .padding()
    }
    .navigationTitle("backgroundStyle")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var consumerRow: some View {
    HStack(spacing: 12) {
      Tile(caption: ".fill(.background)") { swatch(.background) }
      Tile(caption: ".background.secondary") { swatch(.background.secondary) }
      Tile(caption: ".background.tertiary") { swatch(.background.tertiary) }
    }
  }

  /// A bordered swatch filled with the given style, so its bounds stay visible
  /// even when the fill matches the surrounding surface.
  private func swatch(_ style: some ShapeStyle) -> some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(style)
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(.separator)
      }
  }
}

#Preview {
  NavigationStack {
    BackgroundStyleDemoView()
  }
}
