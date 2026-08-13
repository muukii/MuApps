import SwiftUI

/// Analyses `.foregroundStyle(.foreground)` — what the `.foreground` ShapeStyle
/// actually is, and when reaching for it pays off.
///
/// Three facts the demo makes tangible:
///  1. `.foreground` is the DEFAULT. Text and shapes already paint with it, so
///     `.foregroundStyle(.foreground)` on plain content is a visual no-op.
///  2. It earns its keep as a *fill* for things that don't default to the label
///     colour — `Shape().fill(.foreground)`, `.background(.foreground)`,
///     `.stroke(.foreground)` — giving you the adaptive label colour without
///     hardcoding black / white.
///  3. It REFLECTS the current context. Wrap it in `.foregroundStyle(.red)` and
///     it follows to red, exactly like `.primary`. `Color.primary`, by contrast,
///     is a *fixed* label colour that ignores the surrounding style. That gap is
///     invisible by default and only appears once a base style is in play.
///  4. SHAPES are the exception. A shape's colour is its *fill*, not the
///     foreground style. `Rectangle().fill(.foreground)` tracks an inherited
///     colour, but `Rectangle().foregroundStyle(.foreground)` does NOT — the
///     self-referential `.foreground` token collapses to the default label
///     colour for a shape's implicit fill, instead of resolving up to the
///     ancestor style the way `Text` does. Verified on-device.
struct ForegroundStyleDemoView: View {
  @State private var base: BaseStyle = .red

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {

        SectionCard(
          title: "It's the default for content",
          subtitle: "Text already paints with .foreground, so this modifier changes nothing."
        ) {
          HStack(spacing: 12) {
            Tile(caption: "Text(\"Aa\")\n(no modifier)") {
              Text("Aa").font(.title.bold())
            }
            Tile(caption: ".foregroundStyle(.foreground)") {
              Text("Aa").font(.title.bold())
                .foregroundStyle(.foreground)
            }
          }
        }

        SectionCard(
          title: "Where it pays off",
          subtitle: "Paint NON-text with the same adaptive label colour — no hardcoded black/white."
        ) {
          HStack(spacing: 12) {
            Tile(caption: "Circle()\n.fill(.foreground)") {
              Circle()
                .fill(.foreground)
                .frame(width: 40, height: 40)
            }
            Tile(caption: ".background(.foreground)\n+ .foregroundStyle(.background)") {
              Text("Aa")
                .font(.headline)
                .foregroundStyle(.background)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.foreground, in: Capsule())
            }
            Tile(caption: "RoundedRectangle()\n.stroke(.foreground)") {
              RoundedRectangle(cornerRadius: 10)
                .stroke(.foreground, lineWidth: 2)
                .frame(width: 56, height: 40)
            }
          }
        }

        SectionCard(
          title: "It reflects the current style — Color.primary doesn't",
          subtitle: "Pick a base. .foreground and .primary follow it; Color.primary stays the label colour."
        ) {
          Picker("Base", selection: $base) {
            ForEach(BaseStyle.allCases) { style in
              Text(style.label).tag(style)
            }
          }
          .pickerStyle(.segmented)

          CodeText(base.code)

          // The base wraps all three samples. Each sample then sets its OWN
          // foreground style — so we can see which ones honour the base and
          // which one overrides it with a fixed colour.
          HStack(spacing: 12) {
            compareColumn(".foreground") {
              Text("Aa").foregroundStyle(.foreground)
            }
            compareColumn(".primary") {
              Text("Aa").foregroundStyle(.primary)
            }
            compareColumn("Color.primary") {
              Text("Aa").foregroundStyle(Color.primary)
            }
          }
        }

        SectionCard(
          title: "Shapes: paint with .fill, not .foregroundStyle",
          subtitle: "Uses the SAME base as above. A shape's colour is its fill — and with the .foreground token, .foregroundStyle won't track an inherited colour. .fill does."
        ) {
          HStack(spacing: 12) {
            shapeColumn("Rectangle()\n.foregroundStyle(.foreground)\n✗ stays label colour") {
              Rectangle().foregroundStyle(.foreground)
            }
            shapeColumn("Rectangle()\n.fill(.foreground)\n✓ tracks the base") {
              Rectangle().fill(.foreground)
            }
          }
        }

        SectionCard(title: "Cheat sheet", subtitle: nil) {
          VStack(alignment: .leading, spacing: 8) {
            CodeText(".foregroundStyle(.foreground)   // no-op on content (already the default)")
            CodeText("Shape().fill(.foreground)       // paint a shape the label colour — tracks the base")
            CodeText("Shape().foregroundStyle(.foreground)  // ✗ shape WON'T track an inherited colour")
            CodeText(".background(.foreground)        // inverted chip — pair with .foregroundStyle(.background)")
            CodeText(".foreground tracks foregroundStyle;  Color.primary is fixed")
          }
        }
      }
      .padding()
    }
    .navigationTitle("The .foreground style")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// A shape sample filling its column, with the chosen `base` applied as an
  /// ANCESTOR — mirroring `compareColumn`. The shape decides, via its own
  /// `.fill` / `.foregroundStyle`, whether to honour that inherited base.
  private func shapeColumn(
    _ caption: String,
    @ViewBuilder shape: () -> some View
  ) -> some View {
    VStack(spacing: 6) {
      shape()
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .foregroundStyle(base.anyStyle) // the inherited base
        .tint(.orange)
        .animation(.snappy, value: base)
      Text(caption)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// A labelled sample whose "Aa" inherits the chosen `base` foreground style.
  /// The sample's own `.foregroundStyle(…)` is applied closer to the text, so it
  /// decides whether to honour the inherited base or replace it.
  private func compareColumn(
    _ caption: String,
    @ViewBuilder sample: () -> some View
  ) -> some View {
    VStack(spacing: 6) {
      sample()
        .font(.title.bold())
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .foregroundStyle(base.anyStyle) // inherited base — the sample may override it
        .tint(.orange)                  // concrete tint for the .tint base
        .animation(.snappy, value: base)
      Text(caption)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

#Preview {
  NavigationStack {
    ForegroundStyleDemoView()
  }
}
