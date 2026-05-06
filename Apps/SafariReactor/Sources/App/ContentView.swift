import MuDesignSystem
import SwiftUI

struct ContentView: View {
  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "safari")
              .font(.system(size: 44, weight: .semibold))
              .foregroundStyle(MuColors.primary)

            Text("Safari Reactor")
              .font(MuFonts.largeTitle())

            Text("Turn on the Safari extension, open Netflix in Safari on iPad, and use the overlay while the video stays in the normal player.")
              .font(.body)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }

        Section("Setup") {
          SetupStepRow(index: 1, title: "Open Settings", detail: "Go to Settings > Safari > Extensions.")
          SetupStepRow(index: 2, title: "Enable Safari Reactor", detail: "Allow it on netflix.com when Safari asks for website access.")
          SetupStepRow(index: 3, title: "Open Netflix in Safari", detail: "Use the normal player first. Full-screen behavior will be verified later.")
        }

        Section("Development") {
          LabeledContent("Target page", value: "netflix.com/watch")
          LabeledContent("Current milestone", value: "Overlay and subtitle detection")
          LabeledContent("Overlay", value: "Enabled by default")
        }
      }
      .navigationTitle("Safari Reactor")
    }
  }
}

private struct SetupStepRow: View {
  let index: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(index)")
        .font(.headline.monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(Circle().fill(MuColors.primary))

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

#Preview {
  ContentView()
}
