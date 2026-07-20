import MuColor
import SwiftUI

/// An isolated stage for shaping Tinycurve's custom text motion.
///
/// The sandbox reuses the product `TextRenderer` effect while keeping its Replay
/// controls out of onboarding. Tap Replay to restart the per-glyph sequence.
struct TinycurveTextAnimationSandbox: View {

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var replayRequest = 0

  var body: some View {
    PrimaryContainer(accentColor: .default) {
      ZStack {
        Rectangle()
          .fill(.appPrimaryContainer)
          .ignoresSafeArea()

        VStack(spacing: 28) {
          Spacer(minLength: 0)

          VStack(spacing: 14) {
            Text(verbatim: "Tinycurve")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)

            Text("Words, photos, and sounds\neach keep their own shape.")
              .font(.system(.title, design: .rounded, weight: .semibold))
              .foregroundStyle(.appOnPrimaryContainer)
              .multilineTextAlignment(.center)
              .lineSpacing(4)
              .tinycurveTextAppearance(replayRequest: replayRequest)
              .accessibilityAddTraits(.isHeader)
          }

          Spacer(minLength: 0)

          Button {
            replayRequest += 1
          } label: {
            Label("Replay", systemImage: "arrow.counterclockwise")
          }
          .buttonStyle(.glassProminent)
          .disabled(accessibilityReduceMotion)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
      }
    }
  }
}

#Preview("Tinycurve Text Animation") {
  TinycurveTextAnimationSandbox()
}
