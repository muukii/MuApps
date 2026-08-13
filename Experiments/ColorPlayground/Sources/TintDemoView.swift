import SwiftUI

/// Demonstrates what `.tint(_:)` actually reaches — and what it does NOT.
///
/// Key point: `.tint(_:)` seeds a semantic colour in the environment. Standard
/// controls read it automatically; plain content does not, unless you explicitly
/// pull it in with `.foregroundStyle(.tint)`. With no `.tint`, the value falls
/// back to the app's AccentColor (here the system default, since this app ships
/// no AccentColor asset).
struct TintDemoView: View {
  @State private var tint: Color = .pink
  @State private var isOn: Bool = true
  @State private var progress: Double = 0.6

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {

        SectionCard(
          title: "Pick a tint",
          subtitle: "Everything below inherits it from the environment."
        ) {
          ColorPicker("tint", selection: $tint)
            .font(.subheadline)
          CodeText(".tint(selectedColor)")
        }

        SectionCard(
          title: "Controls adopt tint automatically",
          subtitle: "Buttons, toggles, sliders, progress, links — no extra code."
        ) {
          VStack(alignment: .leading, spacing: 14) {
            Button("Bordered button") {}
              .buttonStyle(.borderedProminent)
            Toggle("Toggle", isOn: $isOn)
            Slider(value: $progress)
            ProgressView(value: progress)
            Link("A link", destination: URL(string: "https://developer.apple.com")!)
          }
        }
        .tint(tint)

        SectionCard(
          title: "Plain content does NOT",
          subtitle: "Text and symbols ignore tint until you ask for it."
        ) {
          HStack(spacing: 12) {
            Tile(caption: "Text(\"Aa\")\n(no modifier)") {
              Text("Aa").font(.title.bold())
            }
            Tile(caption: ".foregroundStyle(.tint)") {
              Text("Aa").font(.title.bold())
                .foregroundStyle(.tint)
            }
            Tile(caption: "Image…\n.foregroundStyle(.tint)") {
              Image(systemName: "star.fill").font(.title)
                .foregroundStyle(.tint)
            }
          }
        }
        .tint(tint)

        SectionCard(
          title: "Default = app AccentColor",
          subtitle: "Remove every .tint and the chain falls back to the accent color."
        ) {
          Text("ShapeStyle.tint  =  explicit .tint(…)  ??  app AccentColor")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle("Tint")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    TintDemoView()
  }
}
