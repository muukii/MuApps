import SwiftUI

extension View {

  /// Reveals the text in this view hierarchy with Tinycurve's per-glyph motion.
  ///
  /// Pass an incrementing request from a prototype or control to replay the
  /// effect. Product content can omit it to play once when it first appears.
  func tinycurveTextAppearance(replayRequest: Int = 0) -> some View {
    modifier(TinycurveTextAppearanceModifier(replayRequest: replayRequest))
  }
}

/// Owns the transient clock that drives a `TinycurveTextAppearanceRenderer`.
private struct TinycurveTextAppearanceModifier: ViewModifier {

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var elapsedTime: TimeInterval = 0

  let replayRequest: Int

  func body(content: Content) -> some View {
    content
      .textRenderer(
        TinycurveTextAppearanceRenderer(
          elapsedTime: elapsedTime,
          totalDuration: TinycurveTextAppearanceTiming.totalDuration
        )
      )
      .task(id: playbackID) {
        await playAnimation()
      }
  }

  private var playbackID: TinycurveTextAppearancePlaybackID {
    TinycurveTextAppearancePlaybackID(
      replayRequest: replayRequest,
      accessibilityReduceMotion: accessibilityReduceMotion
    )
  }

  /// Resets without interpolation, then advances one shared linear clock. Each
  /// glyph derives its local timing and spring position from that clock.
  @MainActor
  private func playAnimation() async {
    var resetTransaction = Transaction()
    resetTransaction.disablesAnimations = true

    withTransaction(resetTransaction) {
      elapsedTime = accessibilityReduceMotion
        ? TinycurveTextAppearanceTiming.totalDuration
        : 0
    }

    guard !accessibilityReduceMotion else { return }

    // Commit the reset before beginning a replay, including when a previous
    // request is still settling.
    await Task.yield()
    guard !Task.isCancelled else { return }

    withAnimation(.linear(duration: TinycurveTextAppearanceTiming.totalDuration)) {
      elapsedTime = TinycurveTextAppearanceTiming.totalDuration
    }
  }
}

/// Inputs that determine when the appearance task restarts.
private struct TinycurveTextAppearancePlaybackID: Equatable {

  let replayRequest: Int
  let accessibilityReduceMotion: Bool
}

/// Timing shared by the state driver and text renderer.
private enum TinycurveTextAppearanceTiming {

  /// Duration of one glyph's blur, fade, and vertical settling motion.
  nonisolated static let elementDuration: TimeInterval = 0.48

  /// Duration from the first glyph starting until the final glyph settles.
  static let totalDuration: TimeInterval = 1.18
}

/// Draws a text layout as a calm, left-to-right per-glyph appearance sequence.
///
/// `elapsedTime` is the only animatable value. The renderer maps it to a
/// staggered local time for every glyph, preserving the `Text` view's layout,
/// styling, localization, accessibility semantics, and Dynamic Type behavior.
private struct TinycurveTextAppearanceRenderer: TextRenderer {

  /// Time advanced by the enclosing SwiftUI animation.
  var elapsedTime: TimeInterval

  /// Total time available to the complete glyph sequence.
  let totalDuration: TimeInterval

  var animatableData: Double {
    get { elapsedTime }
    set { elapsedTime = newValue }
  }

  /// Extra drawing room for the initial translation and blur spread.
  var displayPadding: EdgeInsets {
    EdgeInsets(top: 12, leading: 12, bottom: 20, trailing: 12)
  }

  init(elapsedTime: TimeInterval, totalDuration: TimeInterval) {
    self.elapsedTime = min(max(elapsedTime, 0), totalDuration)
    self.totalDuration = totalDuration
  }

  // SwiftUI can invoke TextRenderer on its AsyncRenderer thread, independent
  // of this target's default MainActor isolation.
  nonisolated func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    let glyphs = layout.flatMap { line in
      line.flatMap { run in
        run
      }
    }
    let delay = elementDelay(glyphCount: glyphs.count)

    for (index, glyph) in glyphs.enumerated() {
      let startTime = TimeInterval(index) * delay
      let glyphTime = min(
        max(elapsedTime - startTime, 0),
        TinycurveTextAppearanceTiming.elementDuration
      )
      var glyphContext = context
      draw(glyph, at: glyphTime, in: &glyphContext)
    }
  }

  /// Draws one glyph with opacity and blur easing while a spring controls its
  /// vertical position. Context copying in `draw(layout:in:)` isolates filters.
  nonisolated private func draw(
    _ glyph: Text.Layout.RunSlice,
    at time: TimeInterval,
    in context: inout GraphicsContext
  ) {
    let duration = TinycurveTextAppearanceTiming.elementDuration
    let progress = min(max(time / duration, 0), 1)
    let easedProgress = progress * progress * (3 - 2 * progress)
    let glyphHeight = glyph.typographicBounds.rect.height
    let spring = Spring.smooth(duration: duration, extraBounce: 0)
    let translationY: CGFloat = spring.value(
      fromValue: glyphHeight * 0.36,
      toValue: 0,
      initialVelocity: 0,
      time: time
    )

    context.translateBy(x: 0, y: translationY)
    context.addFilter(.blur(radius: glyphHeight * 0.12 * (1 - easedProgress)))
    context.opacity = min(progress * 1.7, 1)
    context.draw(glyph, options: .disablesSubpixelQuantization)
  }

  /// Fits evenly staggered start times between the first and final glyph while
  /// leaving the full element duration for the last glyph to settle.
  nonisolated private func elementDelay(glyphCount: Int) -> TimeInterval {
    guard glyphCount > 1 else { return 0 }

    let staggerDuration = max(
      totalDuration - TinycurveTextAppearanceTiming.elementDuration,
      0
    )
    return staggerDuration / TimeInterval(glyphCount - 1)
  }
}
