import SwiftUI

/// A prototype scroll surface where cards visually compress upward after layout.
struct FloatingUpStack: View {
  private let scrollCoordinateSpace = "FloatingUpStack.scroll"
  @State private var cards = SampleCard.cards
  @State private var cardHeight: CGFloat = 180
  @State private var stackReveal: CGFloat = 28

  var body: some View {
    ScrollView {
      LazyVStack(spacing: stackSpacing) {
        ForEach(Array(cards.enumerated()), id: \.element.id) { stackIndex, card in
          Card(card: card)
            .frame(height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 8)
            )
            .overlay(alignment: .topTrailing) {
              RemoveCardButton(title: card.title) {
                remove(card)
              }
              .padding(12)
            }
            .overlay(alignment: .top) {
              // A subtle gradient at the top edge enhances the stacked illusion.
              LinearGradient(colors: [Color.black.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .visualEffect { content, geometry in
                  content
                    .opacity(
                      StackVisualMetrics(
                        geometry: geometry,
                        coordinateSpaceName: scrollCoordinateSpace
                      ).isStacked ? 1 : 0
                    )
                }
            }
            .visualEffect { content, geometry in
              content
                .scaleEffect(
                  StackVisualMetrics(
                    geometry: geometry,
                    coordinateSpaceName: scrollCoordinateSpace
                  ).scale
                )
                .offset(
                  y: StackVisualMetrics(
                    geometry: geometry,
                    coordinateSpaceName: scrollCoordinateSpace
                  ).compressedOffset
                )
            }
            .zIndex(Double(stackIndex))
            .padding(.horizontal, 16)
        }
      }
      .padding(.vertical, 24)
    }
    .coordinateSpace(name: scrollCoordinateSpace)
    .background(
      LinearGradient(
        colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .navigationTitle("Floating Stack")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu("Tune") {
          Section("Card Height") {
            Button("Small") { cardHeight = 140 }
            Button("Medium") { cardHeight = 180 }
            Button("Large") { cardHeight = 220 }
          }
          Section("Stack Reveal") {
            Button("Dense") { stackReveal = 18 }
            Button("Deck") { stackReveal = 28 }
            Button("Loose") { stackReveal = 44 }
          }
        }
      }
    }
  }

  private var stackSpacing: CGFloat {
    stackReveal - cardHeight
  }

  private func remove(_ card: SampleCard) {
    withAnimation(.spring(duration: 0.35, bounce: 0.18)) {
      cards.removeAll { $0.id == card.id }
    }
  }
}

/// Derived visual-only values for a card's current scroll position.
private struct StackVisualMetrics {
  let compressedOffset: CGFloat
  let scale: CGFloat
  let isStacked: Bool

  init(geometry: GeometryProxy, coordinateSpaceName: String) {
    self.init(minY: geometry.frame(in: .named(coordinateSpaceName)).minY)
  }

  init(minY: CGFloat) {
    let threshold: CGFloat = 96
    let stackCompression: CGFloat = 0.7
    let overlap = max(0, threshold - max(0, minY))
    let liftedDistance = max(0, -minY)

    compressedOffset = -overlap * stackCompression
    scale = 1 - (liftedDistance / 2000)
    isStacked = liftedDistance > 0
  }
}

private struct Card: View {
  let card: SampleCard

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Artwork / placeholder
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(card.color.gradient)

      VStack(alignment: .leading, spacing: 8) {
        Text(card.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        Text(card.subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.ultraThinMaterial)
          .opacity(0.7)
      )
      .padding(12)
    }
  }
}

/// Compact destructive affordance shown on each stacked card.
private struct RemoveCardButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.primary)
        .frame(width: 32, height: 32)
        .background(.ultraThinMaterial, in: Circle())
        .overlay {
          Circle()
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Remove \(title)"))
  }
}

/// Local sample data used by the floating stack preview surface.
private struct SampleCard: Identifiable, Hashable {
  let id = UUID()
  let title: String
  let subtitle: String
  let color: Color

  static let cards: [SampleCard] = [
    .init(title: "Prologue", subtitle: "A quiet beginning", color: .indigo),
    .init(title: "Chapter 1", subtitle: "Into the valley", color: .mint),
    .init(title: "Chapter 2", subtitle: "Rising action", color: .orange),
    .init(title: "Chapter 3", subtitle: "Twists and turns", color: .pink),
    .init(title: "Chapter 4", subtitle: "Above the clouds", color: .teal),
    .init(title: "Chapter 5", subtitle: "Nightfall", color: .purple),
    .init(title: "Epilogue", subtitle: "Reflections", color: .blue)
  ]
}

#Preview {
  NavigationStack { FloatingUpStack() }
}
