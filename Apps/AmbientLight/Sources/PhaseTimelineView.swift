import SwiftUI

/// Accumulates a shader phase without jumping when speed or activity changes.
///
/// Pausing also pauses phase accumulation, so an offscreen scene does not spend
/// render time or jump ahead when it becomes visible again.
struct PhaseTimelineView<Content: View>: View {
  private let speed: Float
  private let isActive: Bool
  private let minimumInterval: TimeInterval?
  private let content: (_ phase: Double, _ size: CGSize) -> Content

  @State private var phase: Double = 0
  @State private var lastTime: Date?

  init(
    speed: Float,
    isActive: Bool = true,
    minimumInterval: TimeInterval? = nil,
    @ViewBuilder content: @escaping (_ phase: Double, _ size: CGSize) -> Content
  ) {
    self.speed = speed
    self.isActive = isActive
    self.minimumInterval = minimumInterval
    self.content = content
  }

  var body: some View {
    GeometryReader { geometry in
      TimelineView(
        .animation(
          minimumInterval: minimumInterval,
          paused: !isActive
        )
      ) { context in
        content(phase, geometry.size)
          .onChange(of: context.date) { _, newValue in
            guard isActive else {
              lastTime = nil
              return
            }

            guard let lastTime else {
              self.lastTime = newValue
              return
            }

            let delta = newValue.timeIntervalSince(lastTime)
            phase += delta * Double(speed)
            self.lastTime = newValue
          }
          .onAppear {
            lastTime = isActive ? context.date : nil
          }
      }
    }
    .onChange(of: isActive) { _, _ in
      lastTime = nil
    }
    .ignoresSafeArea()
  }
}
