import SwiftUI

/// Placeholder content for a non-control tab. Deliberately tall and scrollable so
/// the tab bar's minimize-on-scroll behaviour is observable.
struct DemoTabContent: View {
  let tab: AppTab

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 12) {
          header
          ForEach(0..<24, id: \.self) { index in
            DemoRow(tab: tab, index: index)
          }
        }
        .padding()
      }
      .navigationTitle(tab.title)
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: tab.systemImage)
        .font(.system(size: 32, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 64, height: 64)
        .background(tab.tint.gradient, in: .rect(cornerRadius: 16))
      VStack(alignment: .leading, spacing: 4) {
        Text(tab.title)
          .font(.title2.weight(.bold))
        Text("Scroll to watch the tab bar respond.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.bottom, 4)
  }
}

// MARK: - Row

private struct DemoRow: View {
  let tab: AppTab
  let index: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: tab.systemImage)
        .foregroundStyle(tab.tint)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(tab.title) item \(index + 1)")
          .font(.headline)
        Text("Row \(index + 1) of 24")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding()
    .background(.thinMaterial, in: .rect(cornerRadius: 14))
  }
}

#Preview {
  DemoTabContent(tab: .home)
}
