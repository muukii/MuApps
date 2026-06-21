import SwiftUI

/// Materials + vibrancy — deliberately framed as a SEPARATE system from
/// `backgroundStyle`.
///
/// A `Material` is a blurred backdrop (it needs content behind it to blur).
/// When you put content with a hierarchical foreground style on top of a
/// material, SwiftUI renders it with *vibrancy* — blending with the backdrop
/// for legibility. That vibrancy comes from the Material, NOT from
/// `.backgroundStyle`; the two only rhyme structurally.
struct MaterialVibrancyDemoView: View {
  @State private var thickness: MaterialThickness = .regular

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {

        Picker("Material", selection: $thickness) {
          ForEach(MaterialThickness.allCases) { option in
            Text(option.label).tag(option)
          }
        }
        .pickerStyle(.segmented)

        card
          .animation(.snappy, value: thickness)

        VStack(alignment: .leading, spacing: 8) {
          Text("Vibrancy ≠ backgroundStyle")
            .font(.headline)
          Text(
            "The frosted look and the adaptive text colour come from the Material backdrop. "
            + ".backgroundStyle only changes what the .background ShapeStyle resolves to — "
            + "it carries no blur and no vibrancy. Different systems that happen to rhyme."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
      .padding()
    }
    .background {
      // A colourful backdrop so the material has something to blur.
      LinearGradient(
        colors: [.orange, .pink, .purple, .blue, .teal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    }
    .navigationTitle("Material & vibrancy")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("primary")
        .foregroundStyle(.primary)
      Text("secondary — vibrant")
        .foregroundStyle(.secondary)
      Text("tertiary — more vibrant")
        .foregroundStyle(.tertiary)
      Divider()
      Text(".background(\(thickness.code), in: …)")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .font(.title3.weight(.semibold))
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(thickness.material, in: RoundedRectangle(cornerRadius: 20))
  }
}

// MARK: - Material options

enum MaterialThickness: String, CaseIterable, Identifiable {
  case ultraThin
  case thin
  case regular
  case thick
  case ultraThick

  var id: String { rawValue }

  var label: String {
    switch self {
    case .ultraThin: return "ultraThin"
    case .thin: return "thin"
    case .regular: return "regular"
    case .thick: return "thick"
    case .ultraThick: return "ultraThick"
    }
  }

  var code: String {
    switch self {
    case .ultraThin: return ".ultraThinMaterial"
    case .thin: return ".thinMaterial"
    case .regular: return ".regularMaterial"
    case .thick: return ".thickMaterial"
    case .ultraThick: return ".ultraThickMaterial"
    }
  }

  var material: Material {
    switch self {
    case .ultraThin: return .ultraThinMaterial
    case .thin: return .thinMaterial
    case .regular: return .regularMaterial
    case .thick: return .thickMaterial
    case .ultraThick: return .ultraThickMaterial
    }
  }
}

#Preview {
  NavigationStack {
    MaterialVibrancyDemoView()
  }
}
