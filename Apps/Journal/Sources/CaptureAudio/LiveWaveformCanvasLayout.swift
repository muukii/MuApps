import CoreGraphics
import Foundation

/// Deterministic geometry for the live recording waveform's Canvas renderer.
///
/// The renderer supplies one more sample than `visibleBarCount`: the first bar
/// exits on the leading edge while the last bar enters from beyond the trailing
/// edge. `phase` advances from zero to one between recorder measurements.
struct LiveWaveformCanvasLayout: Sendable, Equatable {
  let barWidth: CGFloat
  let barStride: CGFloat
  let horizontalOffset: CGFloat
  let canvasHeight: CGFloat
  let minimumBarHeight: CGFloat

  init(
    size: CGSize,
    visibleBarCount: Int,
    phase: CGFloat,
    barSpacing: CGFloat = 3,
    minimumBarHeight: CGFloat = 4
  ) {
    precondition(visibleBarCount > 0)

    let canvasWidth = max(size.width, 0)
    let canvasHeight = max(size.height, 0)
    let spacing = max(barSpacing, 0)
    let totalSpacing = spacing * CGFloat(visibleBarCount - 1)
    let barWidth = max(
      (canvasWidth - totalSpacing) / CGFloat(visibleBarCount),
      1
    )
    let barStride = barWidth + spacing

    self.barWidth = barWidth
    self.barStride = barStride
    self.horizontalOffset = -min(max(phase, 0), 1) * barStride
    self.canvasHeight = canvasHeight
    self.minimumBarHeight = min(max(minimumBarHeight, 0), canvasHeight)
  }

  /// Returns the normalized one-slot travel completed since the latest sample.
  static func scrollPhase(
    at date: Date,
    newestSampleDate: Date?,
    sampleInterval: TimeInterval
  ) -> CGFloat {
    precondition(sampleInterval > 0)
    guard let newestSampleDate else { return 0 }
    let elapsed = date.timeIntervalSince(newestSampleDate)
    return min(max(CGFloat(elapsed / sampleInterval), 0), 1)
  }

  /// Returns one vertically centered capsule rectangle at its current scroll position.
  func barRect(for sample: Float, at index: Int) -> CGRect {
    let amplitude = CGFloat(min(max(sample, 0), 1))
    let height = minimumBarHeight + (canvasHeight - minimumBarHeight) * amplitude
    return CGRect(
      x: CGFloat(index) * barStride + horizontalOffset,
      y: (canvasHeight - height) / 2,
      width: barWidth,
      height: height
    )
  }
}
