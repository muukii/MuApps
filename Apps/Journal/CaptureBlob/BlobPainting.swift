import SwiftUI
import UIKit

// MARK: - Vector model

/// One timestamped centerline sample for a filled blob layer.
///
/// Blob painting stores the user's gesture as a centerline plus a layer width.
/// Rendering turns that centerline into a closed filled ribbon, which keeps the
/// persisted model compact while allowing thumbnails and future re-rendering.
public struct BlobPoint: Sendable, Equatable, Codable {
  public var x: Double
  public var y: Double
  public var time: TimeInterval

  public init(x: Double, y: Double, time: TimeInterval) {
    self.x = x
    self.y = y
    self.time = time
  }

  var location: CGPoint {
    CGPoint(x: x, y: y)
  }
}

/// Codable RGBA color used by blob gradients.
///
/// `SwiftUI.Color` is intentionally not stored directly because a captured blob
/// should be serializable without depending on an environment palette.
public struct BlobColor: Sendable, Equatable, Codable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var opacity: Double

  public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  var color: Color {
    Color(red: red, green: green, blue: blue, opacity: opacity)
  }
}

/// A serializable `UnitPoint` for gradient direction.
public struct BlobUnitPoint: Sendable, Equatable, Codable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  var unitPoint: UnitPoint {
    UnitPoint(x: x, y: y)
  }
}

/// Visual style for a blob layer.
///
/// Each layer owns its gradient instead of reading app theme color. This lets
/// the shape-painting experiment explore translucent color composition without
/// coupling it to Journal's text/doodle theme model.
public struct BlobGradientStyle: Sendable, Equatable, Codable, Identifiable {
  public var id: String
  public var name: String
  public var startColor: BlobColor
  public var middleColor: BlobColor?
  public var endColor: BlobColor
  public var startPoint: BlobUnitPoint
  public var endPoint: BlobUnitPoint
  public var opacity: Double

  public init(
    id: String,
    name: String,
    startColor: BlobColor,
    middleColor: BlobColor? = nil,
    endColor: BlobColor,
    startPoint: BlobUnitPoint = BlobUnitPoint(x: 0, y: 0.2),
    endPoint: BlobUnitPoint = BlobUnitPoint(x: 1, y: 0.8),
    opacity: Double = 0.92
  ) {
    self.id = id
    self.name = name
    self.startColor = startColor
    self.middleColor = middleColor
    self.endColor = endColor
    self.startPoint = startPoint
    self.endPoint = endPoint
    self.opacity = opacity
  }

  static let presets: [BlobGradientStyle] = [
    BlobGradientStyle(
      id: "midnight-cobalt",
      name: "Midnight Cobalt",
      startColor: BlobColor(red: 0.05, green: 0.12, blue: 0.55),
      middleColor: BlobColor(red: 0.02, green: 0.28, blue: 0.92),
      endColor: BlobColor(red: 0.12, green: 0.02, blue: 0.20),
      startPoint: BlobUnitPoint(x: 0.02, y: 0.28),
      endPoint: BlobUnitPoint(x: 0.98, y: 0.72),
      opacity: 0.94
    ),
    BlobGradientStyle(
      id: "sky-ultramarine",
      name: "Sky Ultramarine",
      startColor: BlobColor(red: 0.50, green: 0.68, blue: 1.0),
      middleColor: BlobColor(red: 0.17, green: 0.38, blue: 1.0),
      endColor: BlobColor(red: 0.0, green: 0.18, blue: 0.86),
      startPoint: BlobUnitPoint(x: 0, y: 0.7),
      endPoint: BlobUnitPoint(x: 1, y: 0.25),
      opacity: 0.88
    ),
    BlobGradientStyle(
      id: "rose-periwinkle",
      name: "Rose Periwinkle",
      startColor: BlobColor(red: 1.0, green: 0.72, blue: 0.78),
      middleColor: BlobColor(red: 0.98, green: 0.88, blue: 0.95),
      endColor: BlobColor(red: 0.56, green: 0.60, blue: 1.0),
      startPoint: BlobUnitPoint(x: 0.05, y: 0.55),
      endPoint: BlobUnitPoint(x: 0.95, y: 0.45),
      opacity: 0.82
    ),
    BlobGradientStyle(
      id: "violet-aqua",
      name: "Violet Aqua",
      startColor: BlobColor(red: 0.54, green: 0.40, blue: 1.0),
      middleColor: BlobColor(red: 0.28, green: 0.78, blue: 0.92),
      endColor: BlobColor(red: 0.08, green: 0.08, blue: 0.25),
      startPoint: BlobUnitPoint(x: 0.05, y: 0.15),
      endPoint: BlobUnitPoint(x: 0.95, y: 0.95),
      opacity: 0.86
    ),
  ]
}

/// One filled gradient shape in a blob painting.
public struct BlobLayer: Sendable, Equatable, Codable, Identifiable {
  public var id: UUID
  public var points: [BlobPoint]
  public var width: Double
  public var style: BlobGradientStyle

  public init(
    id: UUID = UUID(),
    points: [BlobPoint],
    width: Double,
    style: BlobGradientStyle
  ) {
    self.id = id
    self.points = points
    self.width = width
    self.style = style
  }
}

/// A finished abstract shape painting.
///
/// Unlike `DoodleDrawing`, this is not stroke ink. It is an ordered stack of
/// translucent filled ribbons where each layer owns its gradient and width.
public struct BlobPainting: Sendable, Equatable, Codable {
  public var layers: [BlobLayer]
  public var canvasSize: CGSize
  public var duration: TimeInterval

  public init(layers: [BlobLayer], canvasSize: CGSize, duration: TimeInterval) {
    self.layers = layers
    self.canvasSize = canvasSize
    self.duration = duration
  }

  public var isEmpty: Bool {
    layers.allSatisfy { $0.points.isEmpty }
  }

  /// Rasterizes the vector layers into a transparent image.
  ///
  /// Pass `scale` from a view context when the target screen scale matters.
  @MainActor
  public func image(scale: CGFloat? = nil) -> UIImage? {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
    let renderer = ImageRenderer(
      content: BlobPaintingRenderer(layers: layers, liveLayer: nil)
        .frame(width: canvasSize.width, height: canvasSize.height)
    )
    let resolvedScale = scale ?? UITraitCollection.current.displayScale
    renderer.scale = resolvedScale > 0 ? resolvedScale : 1
    renderer.isOpaque = false
    return renderer.uiImage
  }
}

// MARK: - Rendering

struct BlobPaintingRenderer: View {
  let layers: [BlobLayer]
  let liveLayer: BlobLayer?

  var body: some View {
    ZStack {
      ForEach(layers) { layer in
        BlobLayerView(layer: layer)
      }

      if let liveLayer {
        BlobLayerView(layer: liveLayer)
      }
    }
    .compositingGroup()
    .drawingGroup()
  }
}

private struct BlobLayerView: View {
  let layer: BlobLayer

  var body: some View {
    BlobLayerShape(layer: layer)
      .fill(gradient)
      .opacity(layer.style.opacity)
  }

  private var gradient: LinearGradient {
    LinearGradient(
      stops: gradientStops,
      startPoint: layer.style.startPoint.unitPoint,
      endPoint: layer.style.endPoint.unitPoint
    )
  }

  private var gradientStops: [Gradient.Stop] {
    if let middleColor = layer.style.middleColor {
      return [
        Gradient.Stop(color: layer.style.startColor.color, location: 0),
        Gradient.Stop(color: middleColor.color, location: 0.52),
        Gradient.Stop(color: layer.style.endColor.color, location: 1),
      ]
    }

    return [
      Gradient.Stop(color: layer.style.startColor.color, location: 0),
      Gradient.Stop(color: layer.style.endColor.color, location: 1),
    ]
  }
}

private struct BlobLayerShape: Shape {
  let layer: BlobLayer

  func path(in rect: CGRect) -> Path {
    BlobRibbonPath.make(
      points: layer.points.map(\.location),
      width: CGFloat(layer.width)
    )
  }
}

private enum BlobRibbonPath {

  static func make(points: [CGPoint], width: CGFloat) -> Path {
    let points = points.removingNearDuplicates(minDistance: 0.5)
    guard let first = points.first else { return Path() }

    let halfWidth = max(width / 2, 1)
    guard points.count > 1 else {
      return Path(ellipseIn: CGRect(
        x: first.x - halfWidth,
        y: first.y - halfWidth,
        width: halfWidth * 2,
        height: halfWidth * 2
      ))
    }

    let tangents = tangents(for: points)
    let leftEdge = points.indices.map { index in
      let normal = tangents[index].leftNormal
      return points[index] + normal * halfWidth
    }
    let rightEdge = points.indices.map { index in
      let normal = tangents[index].leftNormal
      return points[index] - normal * halfWidth
    }

    var path = Path()
    path.move(to: leftEdge[0])
    appendSmoothEdge(leftEdge, to: &path)

    let endCapControl = points[points.count - 1] + tangents[tangents.count - 1] * halfWidth
    path.addQuadCurve(to: rightEdge[rightEdge.count - 1], control: endCapControl)

    appendSmoothEdge(rightEdge.reversed(), to: &path)

    let startCapControl = points[0] - tangents[0] * halfWidth
    path.addQuadCurve(to: leftEdge[0], control: startCapControl)
    path.closeSubpath()
    return path
  }

  private static func appendSmoothEdge<S: Sequence>(
    _ source: S,
    to path: inout Path
  ) where S.Element == CGPoint {
    let points = Array(source)
    guard points.count > 1 else { return }

    if points.count == 2 {
      path.addLine(to: points[1])
      return
    }

    for index in 1..<(points.count - 1) {
      let current = points[index]
      let next = points[index + 1]
      path.addQuadCurve(to: current.midpoint(to: next), control: current)
    }

    path.addQuadCurve(to: points[points.count - 1], control: points[points.count - 2])
  }

  private static func tangents(for points: [CGPoint]) -> [CGVector] {
    points.indices.map { index in
      let previous = points[max(index - 1, 0)]
      let next = points[min(index + 1, points.count - 1)]
      let vector = CGVector(dx: next.x - previous.x, dy: next.y - previous.y)
      return vector.normalized(fallback: CGVector(dx: 1, dy: 0))
    }
  }
}

// MARK: - Geometry

extension CGPoint {

  fileprivate static func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
  }

  fileprivate static func - (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x - vector.dx, y: point.y - vector.dy)
  }

  func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }

  func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(
      x: x + (point.x - x) * progress,
      y: y + (point.y - y) * progress
    )
  }

  func midpoint(to point: CGPoint) -> CGPoint {
    CGPoint(x: (x + point.x) / 2, y: (y + point.y) / 2)
  }
}

extension CGVector {

  fileprivate static func * (vector: CGVector, scalar: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
  }

  fileprivate var leftNormal: CGVector {
    CGVector(dx: -dy, dy: dx)
  }

  fileprivate func normalized(fallback: CGVector) -> CGVector {
    let length = hypot(dx, dy)
    guard length > 0.001 else { return fallback }
    return CGVector(dx: dx / length, dy: dy / length)
  }
}

extension [CGPoint] {

  fileprivate func removingNearDuplicates(minDistance: CGFloat) -> [CGPoint] {
    var result: [CGPoint] = []
    for point in self {
      guard let previous = result.last else {
        result.append(point)
        continue
      }

      if previous.distance(to: point) >= minDistance {
        result.append(point)
      }
    }
    return result
  }
}
