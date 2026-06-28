import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Vector model

/// One timestamped sample along a stroke.
///
/// `time` is seconds from the first point of the whole drawing, so every stroke
/// shares one replay timeline. `width` is optional for backward compatibility:
/// old drawings fall back to the owning `DoodleStroke.width`, while new strokes
/// can store a velocity-shaped width per point.
public struct DoodlePoint: Sendable, Equatable, Codable {
  public var x: Double
  public var y: Double
  public var time: TimeInterval
  public var width: Double?

  public init(x: Double, y: Double, time: TimeInterval, width: Double? = nil) {
    self.x = x
    self.y = y
    self.time = time
    self.width = width
  }

  var location: CGPoint { CGPoint(x: x, y: y) }
}

/// A single continuous stroke.
///
/// `width` is the base brush width; individual `DoodlePoint.width` values can
/// override it to create speed-driven tapering. The stroke is deliberately
/// **colorless**: the ink color is the app's theme color, applied when rendered,
/// so changing the theme re-tints every doodle without touching stored data.
public struct DoodleStroke: Sendable, Equatable, Codable {
  public var points: [DoodlePoint]
  public var width: Double

  public init(points: [DoodlePoint], width: Double) {
    self.points = points
    self.width = width
  }
}

/// A finished doodle as resolution-independent vector strokes on a fixed canvas.
/// Replaces the old flattened PNG: color lives in the theme (not here) and the
/// per-point timestamps make playback possible. The host decides whether to
/// persist it — this stays persistence-agnostic.
public struct DoodleDrawing: Sendable, Equatable, Codable {
  public var strokes: [DoodleStroke]
  /// Point size the strokes were authored in. Lets a consumer scale the vector to
  /// any target size.
  public var canvasSize: CGSize
  /// Time of the last point — the full length of a replay.
  public var duration: TimeInterval

  public init(strokes: [DoodleStroke], canvasSize: CGSize, duration: TimeInterval) {
    self.strokes = strokes
    self.canvasSize = canvasSize
    self.duration = duration
  }

  public var isEmpty: Bool { strokes.allSatisfy { $0.points.isEmpty } }

  /// Rasterizes the vector strokes into a transparent image, tinted with
  /// `inkColor`. For thumbnails / sharing only — the drawing itself stays vector.
  /// Pass `scale` from a view context when the target screen scale matters.
  @MainActor
  public func image(inkColor: Color, scale: CGFloat? = nil) -> UIImage? {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
    let renderer = ImageRenderer(
      content: DoodleStrokesView(strokes: strokes, liveStroke: nil, inkColor: inkColor, revealedTime: nil)
        .frame(width: canvasSize.width, height: canvasSize.height)
    )
    let resolvedScale = scale ?? UITraitCollection.current.displayScale
    renderer.scale = resolvedScale > 0 ? resolvedScale : 1
    renderer.isOpaque = false
    return renderer.uiImage
  }
}

/// Read-only SwiftUI rendering for a saved `DoodleDrawing`.
///
/// The drawing stays vector data: this view scales the authored canvas into the
/// available layout space and renders the strokes with SwiftUI `Canvas` instead
/// of first flattening them into an image.
public struct DoodleDrawingView: View {

  public let drawing: DoodleDrawing
  public let inkColor: Color
  /// Width divided by height for the visible drawing surface.
  ///
  /// Leave this as `nil` to use the authored canvas size. Pass a value when a
  /// host surface, such as a journal card, owns the visual aspect ratio while the
  /// strokes should still be scaled without distortion inside that surface.
  public let displayAspectRatio: CGFloat?

  public init(
    drawing: DoodleDrawing,
    inkColor: Color,
    displayAspectRatio: CGFloat? = nil
  ) {
    self.drawing = drawing
    self.inkColor = inkColor
    self.displayAspectRatio = displayAspectRatio
  }

  public var body: some View {
    if let canvasSize = drawing.validCanvasSize {
      GeometryReader { proxy in
        let fitted = DoodleDrawingFittedLayout(
          sourceSize: canvasSize,
          containerSize: proxy.size
        )

        DoodleStrokesView(
          strokes: drawing.strokes,
          liveStroke: nil,
          inkColor: inkColor,
          revealedTime: nil
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
        .scaleEffect(fitted.scale, anchor: .topLeading)
        .frame(width: fitted.size.width, height: fitted.size.height, alignment: .topLeading)
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      }
      .aspectRatio(
        doodleDisplayAspectRatio(displayAspectRatio, canvasSize: canvasSize),
        contentMode: .fit
      )
    } else {
      Color.clear
    }
  }
}

/// Read-only SwiftUI replay for a saved `DoodleDrawing`.
///
/// The caller owns the playback state through `isPlaying`, while this view owns
/// only the drawing timeline. Long pen-up gaps are compressed for playback, just
/// like `DoodleCanvasView`, so replay shows the authored strokes without making
/// the viewer wait through every pause between strokes.
public struct DoodleDrawingReplayView: View {

  public let drawing: DoodleDrawing
  public let inkColor: Color
  /// Width divided by height for the visible replay surface.
  ///
  /// Leave this as `nil` to replay in the authored canvas aspect. Hosts that
  /// present doodles inside a fixed paper shape can pass that shape's aspect
  /// ratio while preserving the saved stroke geometry.
  public let displayAspectRatio: CGFloat?

  @Binding private var isPlaying: Bool
  @State private var replayStart: Date?

  public init(
    drawing: DoodleDrawing,
    inkColor: Color,
    displayAspectRatio: CGFloat? = nil,
    isPlaying: Binding<Bool>
  ) {
    self.drawing = drawing
    self.inkColor = inkColor
    self.displayAspectRatio = displayAspectRatio
    self._isPlaying = isPlaying
  }

  public var body: some View {
    if let canvasSize = drawing.validCanvasSize {
      GeometryReader { proxy in
        let fitted = DoodleDrawingFittedLayout(
          sourceSize: canvasSize,
          containerSize: proxy.size
        )

        DoodleDrawingReplayLayer(
          drawing: drawing,
          inkColor: inkColor,
          replayStart: replayStart,
          isPlaying: $isPlaying
        )
        .frame(width: canvasSize.width, height: canvasSize.height)
        .scaleEffect(fitted.scale, anchor: .topLeading)
        .frame(width: fitted.size.width, height: fitted.size.height, alignment: .topLeading)
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      }
      .aspectRatio(
        doodleDisplayAspectRatio(displayAspectRatio, canvasSize: canvasSize),
        contentMode: .fit
      )
      .onAppear {
        synchronizeReplayStart()
      }
      .onChange(of: isPlaying) { _, _ in
        synchronizeReplayStart()
      }
      .onChange(of: drawing) { _, _ in
        if isPlaying {
          replayStart = Date()
        }
      }
    } else {
      Color.clear
    }
  }

  private func synchronizeReplayStart() {
    replayStart = isPlaying ? Date() : nil
  }
}

/// The fitted stroke layer for `DoodleDrawingReplayView`.
private struct DoodleDrawingReplayLayer: View {

  let drawing: DoodleDrawing
  let inkColor: Color
  let replayStart: Date?

  @Binding var isPlaying: Bool

  /// Gaps between strokes are shortened for viewing, matching the editor replay.
  private static let replayMaxGap: TimeInterval = 0.35

  var body: some View {
    if let replayStart, isPlaying {
      let replay = drawing.strokes.compressingGaps(maxGap: Self.replayMaxGap)
      let replayDuration = replay.last?.points.last?.time ?? 0

      TimelineView(.animation) { timeline in
        let elapsed = timeline.date.timeIntervalSince(replayStart)
        DoodleStrokesView(
          strokes: replay,
          liveStroke: nil,
          inkColor: inkColor,
          revealedTime: elapsed
        )
        .onChange(of: elapsed >= replayDuration) { _, finished in
          if finished {
            isPlaying = false
          }
        }
      }
    } else {
      DoodleStrokesView(
        strokes: drawing.strokes,
        liveStroke: nil,
        inkColor: inkColor,
        revealedTime: nil
      )
    }
  }
}

private struct DoodleDrawingFittedLayout {
  let sourceSize: CGSize
  let containerSize: CGSize

  var scale: CGFloat {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return 1 }
    return min(containerSize.width / sourceSize.width, containerSize.height / sourceSize.height)
  }

  var size: CGSize {
    CGSize(
      width: sourceSize.width * scale,
      height: sourceSize.height * scale
    )
  }
}

private func doodleDisplayAspectRatio(_ displayAspectRatio: CGFloat?, canvasSize: CGSize) -> CGFloat {
  guard let displayAspectRatio, displayAspectRatio > 0 else {
    return canvasSize.width / canvasSize.height
  }

  return displayAspectRatio
}

private extension DoodleDrawing {
  var validCanvasSize: CGSize? {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
    return canvasSize
  }
}

// MARK: - Rendering

/// Batch stroke renderer used by replay and raster export, where every stroke
/// intentionally redraws into one canvas.
struct DoodleStrokesView: View {

  let strokes: [DoodleStroke]
  let liveStroke: DoodleStroke?
  let inkColor: Color
  /// When non-nil, only the portion of each stroke drawn up to this time is shown
  /// — the mechanism behind replay. `nil` draws everything.
  let revealedTime: TimeInterval?

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
      for stroke in strokes {
        DoodleStrokeRenderer.draw(stroke, upTo: revealedTime, inkColor: inkColor, in: context)
      }
      if let liveStroke {
        DoodleStrokeRenderer.draw(liveStroke, upTo: nil, inkColor: inkColor, in: context)
      }
    }
  }
}

/// Stacks each committed stroke in its own drawing layer, then renders the live
/// stroke above them. During a drag only the live layer changes, so existing ink
/// can stay cached by SwiftUI instead of being redrawn into one large canvas on
/// every touch sample.
struct DoodleLayeredStrokesView: View {

  let strokes: [DoodleStroke]
  let liveStroke: DoodleStroke?
  let inkColor: Color

  var body: some View {
    ZStack {
      ForEach(Array(strokes.enumerated()), id: \.offset) { pair in
        DoodleStrokeLayerView(stroke: pair.element, inkColor: inkColor)
      }

      if let liveStroke {
        DoodleStrokeLayerView(stroke: liveStroke, inkColor: inkColor)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct DoodleStrokeLayerView: View {

  let stroke: DoodleStroke
  let inkColor: Color

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
      DoodleStrokeRenderer.draw(stroke, upTo: nil, inkColor: inkColor, in: context)
    }
  }
}

private enum DoodleStrokeRenderer {

  static func draw(_ stroke: DoodleStroke, upTo limit: TimeInterval?, inkColor: Color, in context: GraphicsContext) {
    let points = stroke.visiblePoints(upTo: limit)
    guard let first = points.first else { return }

    // A tap (or a replay that has only reached the first point) is a single dot;
    // a stroked polyline wouldn't render it, so fill a circle instead.
    guard points.count > 1 else {
      let radius = first.width / 2
      context.fill(
        Path(ellipseIn: CGRect(
          x: first.location.x - radius,
          y: first.location.y - radius,
          width: first.width,
          height: first.width
        )),
        with: .color(inkColor)
      )
      return
    }

    if points.contains(where: \.hasExplicitWidth) {
      drawVariableWidth(points, inkColor: inkColor, in: context)
    } else {
      context.stroke(
        Path(smooth: points.map(\.location)),
        with: .color(inkColor),
        style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
      )
    }
  }

  private static func drawVariableWidth(
    _ points: [DoodleRenderPoint],
    inkColor: Color,
    in context: GraphicsContext
  ) {
    let points = points.removingNearDuplicates()
    guard points.count > 1 else {
      if let point = points.first {
        let radius = point.width / 2
        context.fill(
          Path(ellipseIn: CGRect(
            x: point.location.x - radius,
            y: point.location.y - radius,
            width: point.width,
            height: point.width
          )),
          with: .color(inkColor)
        )
      }
      return
    }

    // Draw dense overlapping round segments instead of one filled offset polygon.
    // Offset polygons fold over at tight turns and crossings; overlapping round
    // strokes keep the centerline dominant and make width changes subtle.
    for index in 1..<points.count {
      let previous = points[index - 1]
      let point = points[index]
      let width = (previous.width + point.width) / 2
      var segment = Path()
      segment.move(to: previous.location)
      segment.addLine(to: point.location)
      context.stroke(
        segment,
        with: .color(inkColor),
        style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
      )
    }
  }
}

private struct DoodleRenderPoint {
  var location: CGPoint
  var width: CGFloat
  var hasExplicitWidth: Bool
}

extension Path {

  /// An open path through `points`, rounding each interior corner with a quadratic
  /// curve whose endpoints are the edge midpoints and whose control point is the
  /// vertex — the standard one-pass smoothing for a hand-drawn polyline. Gives the
  /// line a flowing, pen-like glide on top of the centerline's own smoothing.
  fileprivate init(smooth points: [CGPoint]) {
    self.init()
    guard let first = points.first else { return }
    move(to: first)
    guard points.count > 2 else {
      for point in points.dropFirst() { addLine(to: point) }
      return
    }
    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
      CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    for index in 1..<(points.count - 1) {
      addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
    }
    addQuadCurve(to: points[points.count - 1], control: points[points.count - 2])
  }

}

extension DoodleStroke {

  /// The polyline to draw, optionally truncated at `limit` seconds with the final
  /// segment interpolated so a replay grows smoothly rather than in jumps.
  fileprivate func visiblePoints(upTo limit: TimeInterval?) -> [DoodleRenderPoint] {
    guard let first = points.first else { return [] }

    guard let limit else {
      return points.map { DoodleRenderPoint(point: $0, fallbackWidth: width) }
    }

    guard first.time <= limit else { return [] }
    var result: [DoodleRenderPoint] = [DoodleRenderPoint(point: first, fallbackWidth: width)]
    for index in 1..<max(points.count, 1) {
      let point = points[index]
      if point.time <= limit {
        result.append(DoodleRenderPoint(point: point, fallbackWidth: width))
        continue
      }
      let previous = points[index - 1]
      let span = point.time - previous.time
      let progress = CGFloat(span > 0 ? (limit - previous.time) / span : 1)
      result.append(DoodleRenderPoint(
        location: previous.location.interpolate(to: point.location, progress: progress),
        width: CGFloat(previous.resolvedWidth(fallback: width))
          + (CGFloat(point.resolvedWidth(fallback: width)) - CGFloat(previous.resolvedWidth(fallback: width))) * progress,
        hasExplicitWidth: previous.width != nil || point.width != nil
      ))
      break
    }
    return result
  }
}

extension DoodleRenderPoint {

  init(point: DoodlePoint, fallbackWidth: Double) {
    self.init(
      location: point.location,
      width: CGFloat(point.resolvedWidth(fallback: fallbackWidth)),
      hasExplicitWidth: point.width != nil
    )
  }
}

extension DoodlePoint {

  fileprivate func resolvedWidth(fallback: Double) -> Double {
    width ?? fallback
  }
}

extension [DoodleRenderPoint] {

  fileprivate func removingNearDuplicates() -> [DoodleRenderPoint] {
    var result: [DoodleRenderPoint] = []
    for point in self {
      guard let previous = result.last else {
        result.append(point)
        continue
      }
      if previous.location.distance(to: point.location) > 0.2 {
        result.append(point)
      }
    }
    return result
  }
}
