import SwiftUI

/// Accessory shown above the tab bar (iOS 26). It reports the current style and
/// its own placement so the expanded ⇄ inline transition is visible while the bar
/// minimizes.
struct BottomAccessoryView: View {
  let config: LabConfiguration
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "wand.and.stars")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(config.placement.title)
          .font(.subheadline.weight(.semibold))
        Text(placementText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
  }

  private var placementText: String {
    guard let placement else {
      return "accessory: hidden"
    }
    switch placement {
    case .expanded:
      return "accessory: expanded"
    case .inline:
      return "accessory: inline"
    @unknown default:
      return "accessory: —"
    }
  }
}
