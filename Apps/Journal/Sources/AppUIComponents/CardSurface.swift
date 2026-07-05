import MuColor
import SwiftUI

/// The shared visual identity of a journal card.
///
/// A card is a 4:5 portrait sheet with continuous rounded corners and the
/// palette's paper fill. Every place a card appears (the compose surface, the
/// list tiles, and eventually the widget) is built on this, so they read as the
/// *same* object rather than three look-alikes that drift apart.
///
/// `CardSurface` owns only the **chrome**: proportion, shape, fill, and inset.
/// It also clips child rendering to the paper shape, so UIKit-backed previews
/// and large media cannot spill into neighboring cards.
/// What sits inside — an editable body, a saved note, a date header — stays with
/// the caller, because those layouts genuinely differ (the compose card edits
/// its body and shows a send button; a tile pins its title to the top and date
/// to the bottom). Folding them together would mean a flag per variation, which
/// costs more than it saves.
public struct CardSurface<Content: View>: View {

  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)

    shape
      .fill(.appSecondaryContainer)
      .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
      .overlay {
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .foregroundStyle(.appOnSecondaryContainer)
      }
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(
          Color.init(white: 0.5).opacity(0.1),
          style: .init(lineWidth: 4)
        )
      }
  }
}

/// Dimensions shared by every card so the look stays identical wherever a card
/// is drawn. Centralized here rather than re-declared per call site.
public enum CardMetrics {
  /// Width ÷ height for the canonical 4:5 portrait card.
  public static let aspectRatio: CGFloat = 4 / 5
  public static let cornerRadius: CGFloat = 32
  public static let padding: CGFloat = 16
}

#Preview {
  PrimaryContainer(theme: .default) {
    CardSurface {
      Text("The body of a card goes here.")
        .font(.system(size: 28, weight: .bold))
    }
    .padding(32)
  }
}
