import SwiftUI

/// Demonstrates that `.primary` / `.secondary` / `.tertiary` / `.quaternary` are
/// *levels of the current foreground style*, not fixed grays.
///
/// Switch the base style and watch all four rows recolour together: under a red
/// base, `.secondary` is dimmed red — not system gray. This is exactly why, inside
/// a parent `.foregroundStyle(.tint)`, a child `.foregroundStyle(.primary)`
/// resolves to the tint, and `.secondary` to a de-emphasised tint.
struct ForegroundHierarchyDemoView: View {
  @State private var base: BaseStyle = .systemDefault

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {

        SectionCard(
          title: "Current foreground style",
          subtitle: "This becomes the base that the levels below derive from."
        ) {
          Picker("Base", selection: $base) {
            ForEach(BaseStyle.allCases) { style in
              Text(style.label).tag(style)
            }
          }
          .pickerStyle(.segmented)
          CodeText(base.code)
        }

        SectionCard(
          title: "The four hierarchical levels",
          subtitle: "Same base, progressively de-emphasised. Never a fixed gray."
        ) {
          VStack(spacing: 0) {
            levelRow(".primary") { Text("primary").foregroundStyle(.primary) }
            Divider()
            levelRow(".secondary") { Text("secondary").foregroundStyle(.secondary) }
            Divider()
            levelRow(".tertiary") { Text("tertiary").foregroundStyle(.tertiary) }
            Divider()
            levelRow(".quaternary") { Text("quaternary").foregroundStyle(.quaternary) }
          }
          // Apply the chosen base as the *current* foreground style for the rows.
          .foregroundStyle(base.anyStyle)
          .font(.title3.weight(.semibold))
          .animation(.snappy, value: base)
        }
        // The tint base needs a concrete tint to resolve against.
        .tint(.orange)

        SectionCard(
          title: "Why this matters",
          subtitle: nil
        ) {
          Text(
            "Inside a parent .foregroundStyle(.tint), a child's .foregroundStyle(.primary) "
            + "is the tint at full strength, and .secondary is the tint de-emphasised — "
            + "NOT the default label colour. .primary only equals the label colour when no "
            + "foregroundStyle is in effect."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle("Foreground hierarchy")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func levelRow(
    _ name: String,
    @ViewBuilder sample: () -> some View
  ) -> some View {
    HStack {
      sample()
      Spacer()
      Text(name)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 10)
  }
}

// MARK: - Base style options

enum BaseStyle: String, CaseIterable, Identifiable {
  case systemDefault
  case tint
  case red
  case indigo

  var id: String { rawValue }

  var label: String {
    switch self {
    case .systemDefault: return "default"
    case .tint: return "tint"
    case .red: return "red"
    case .indigo: return "indigo"
    }
  }

  var code: String {
    switch self {
    case .systemDefault: return ".foregroundStyle(.foreground)"
    case .tint: return ".foregroundStyle(.tint)   // .tint(.orange) above"
    case .red: return ".foregroundStyle(.red)"
    case .indigo: return ".foregroundStyle(.indigo)"
    }
  }

  var anyStyle: AnyShapeStyle {
    switch self {
    case .systemDefault: return AnyShapeStyle(.foreground)
    case .tint: return AnyShapeStyle(.tint)
    case .red: return AnyShapeStyle(Color.red)
    case .indigo: return AnyShapeStyle(Color.indigo)
    }
  }
}

#Preview {
  NavigationStack {
    ForegroundHierarchyDemoView()
  }
}
