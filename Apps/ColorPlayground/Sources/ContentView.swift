import SwiftUI

struct ContentView: View {
  var body: some View {
    NavigationStack {
      List {
        Section {
          CheatSheet()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        Section("Demos") {
          NavigationLink {
            TintDemoView()
          } label: {
            DemoRow(
              index: 1,
              title: "Tint propagation",
              detail: ".tint colours controls; .foregroundStyle(.tint) pulls it into content"
            )
          }

          NavigationLink {
            ForegroundHierarchyDemoView()
          } label: {
            DemoRow(
              index: 2,
              title: "foregroundStyle hierarchy",
              detail: ".primary/.secondary are levels of the current style — not fixed gray"
            )
          }

          NavigationLink {
            ForegroundStyleDemoView()
          } label: {
            DemoRow(
              index: 3,
              title: "The .foreground style",
              detail: ".fill(.foreground) tracks the current foreground style; Color.primary is fixed"
            )
          }

          NavigationLink {
            BackgroundStyleDemoView()
          } label: {
            DemoRow(
              index: 4,
              title: "backgroundStyle",
              detail: "Sets what .background resolves to — it paints nothing by itself"
            )
          }

          NavigationLink {
            MaterialVibrancyDemoView()
          } label: {
            DemoRow(
              index: 5,
              title: "Material & vibrancy",
              detail: "Foreground hierarchy over a Material becomes vibrant — a separate system"
            )
          }
        }
      }
      .navigationTitle("Color Playground")
    }
  }
}

// MARK: - Fileprivate Views

private struct DemoRow: View {
  let index: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 14) {
      Text(index.description)
        .font(.headline.monospacedDigit())
        .foregroundStyle(.tint)
        .frame(width: 28, height: 28)
        .background(.tint.tertiary, in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

/// One-screen mental model. The four lines are the whole story; the demos prove them.
private struct CheatSheet: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("The model in 4 lines")
        .font(.headline)

      VStack(alignment: .leading, spacing: 10) {
        bullet(".tint(c)", "sets a semantic colour in the environment — read by controls and by .foregroundStyle(.tint)")
        bullet(".foregroundStyle(s)", "paints content now AND becomes the 'current foreground style'")
        bullet(".primary / .secondary", "the Nth level of that current style — de-emphasised, not a fixed gray")
        bullet(".backgroundStyle(s)", "only changes what the .background ShapeStyle resolves to — paints nothing alone")
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.tint.quaternary, in: RoundedRectangle(cornerRadius: 20))
    .padding(.vertical, 4)
  }

  private func bullet(_ code: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(code)
        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
        .foregroundStyle(.tint)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  ContentView()
}
