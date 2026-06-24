import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Vector model

/// One timestamped sample along a stroke. `time` is seconds from the first point
/// of the whole drawing (so every stroke shares one timeline), which is what lets
/// the drawing be replayed at the speed it was drawn.
public struct DoodlePoint: Sendable, Equatable, Codable {
  public var x: Double
  public var y: Double
  public var time: TimeInterval

  public init(x: Double, y: Double, time: TimeInterval) {
    self.x = x
    self.y = y
    self.time = time
  }

  var location: CGPoint { CGPoint(x: x, y: y) }
}

/// A single continuous stroke: smoothed, timestamped points plus the width it was
/// drawn at. Deliberately **colorless** — the ink color is the app's theme color,
/// applied when the stroke is rendered, so changing the theme re-tints every
/// doodle without touching stored data.
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
  @MainActor
  public func image(inkColor: Color, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
    let renderer = ImageRenderer(
      content: DoodleStrokesView(strokes: strokes, liveStroke: nil, inkColor: inkColor, revealedTime: nil)
        .frame(width: canvasSize.width, height: canvasSize.height)
    )
    renderer.scale = scale
    renderer.isOpaque = false
    return renderer.uiImage
  }
}

// MARK: - Smoothing config

/// Stroke smoothing configuration, ported from Brightroom. `.bezier` at a fairly
/// strong strength is the default (velocity-aware lag + streaming cubic Bézier).
public struct InkSmoothing: Equatable, Sendable {

  public enum Algorithm: String, CaseIterable, Sendable, Identifiable {
    case raw
    case bezier
    case catmullRom
    case movingAverage

    public var id: String { rawValue }
  }

  public var algorithm: Algorithm
  public var strength: Double

  public init(algorithm: Algorithm = .bezier, strength: Double = 0.92) {
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
    let visible = stroke.visiblePoints(upTo: limit)
    guard let first = visible.first else { return }

    // A tap (or a replay that has only reached the first point) is a single dot;
    // a degenerate polyline wouldn't render, so fill a circle instead.
    guard visible.count > 1 else {
      let radius = stroke.width / 2
      let dot = Path(ellipseIn: CGRect(
        x: first.x - radius, y: first.y - radius, width: stroke.width, height: stroke.width
      ))
      context.fill(dot, with: .color(inkColor))
      return
    }

    var path = Path()
    path.addLines(visible)
    context.stroke(
      path,
      with: .color(inkColor),
      style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
    )
  }
}

extension DoodleStroke {

  /// The polyline to draw, optionally truncated at `limit` seconds with the final
  /// segment interpolated so a replay grows smoothly rather than in jumps.
  func visiblePoints(upTo limit: TimeInterval?) -> [CGPoint] {
    guard let first = points.first else { return [] }

    guard let limit else {
      return points.map(\.location)
    }

    guard first.time <= limit else { return [] }
    var result: [CGPoint] = [first.location]
    for index in 1..<max(points.count, 1) {
      let point = points[index]
      if point.time <= limit {
        result.append(point.location)
        continue
      }
      let previous = points[index - 1]
      let span = point.time - previous.time
      let progress = span > 0 ? (limit - previous.time) / span : 1
      result.append(previous.location.interpolate(to: point.location, progress: CGFloat(progress)))
      break
    }
    return result
  }
}
