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

// MARK: - Smoothing config

/// Stroke smoothing configuration for the doodle brush.
///
/// The default `.streamline` mode is intentionally stronger than PencilKit:
/// timestamped coalesced touches flow through an incremental trajectory filter
/// and streaming spline while the finger is down. The emitted live centerline is
/// also the saved centerline, so lifting the finger does not run a second
/// geometry pass that changes the stroke shape.
public struct InkSmoothing: Equatable, Sendable {

  public enum Algorithm: String, CaseIterable, Sendable, Identifiable {
    case raw
    case streamline
    case bezier
    case catmullRom
    case movingAverage

    public var id: String { rawValue }
  }

  public var algorithm: Algorithm
  public var strength: Double

  public init(algorithm: Algorithm = .streamline, strength: Double = 0.99) {
    self.algorithm = algorithm
    self.strength = strength
  }
}

// MARK: - Rendering

/// Shared stroke renderer used by both the live canvas and the raster export, so
/// the on-screen ink and an exported thumbnail are pixel-identical.
struct DoodleStrokesView: View {

  let strokes: [DoodleStroke]
  let liveStroke: DoodleStroke?
  let inkColor: Color
  /// When non-nil, only the portion of each stroke drawn up to this time is shown
  /// — the mechanism behind replay. `nil` draws everything.
  let revealedTime: TimeInterval?

  var body: some View {
    Canvas { context, _ in
      for stroke in strokes {
        draw(stroke, upTo: revealedTime, in: context)
      }
      if let liveStroke {
        draw(liveStroke, upTo: nil, in: context)
      }
    }
  }

  private func draw(_ stroke: DoodleStroke, upTo limit: TimeInterval?, in context: GraphicsContext) {
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
      drawVariableWidth(points, in: context)
    } else {
      context.stroke(
        Path(smooth: points.map(\.location)),
        with: .color(inkColor),
        style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
      )
    }
  }

  private func drawVariableWidth(_ points: [DoodleRenderPoint], in context: GraphicsContext) {
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
