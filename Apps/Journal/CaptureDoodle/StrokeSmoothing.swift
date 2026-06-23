import CoreGraphics

// Stroke smoothing ported from FluidGroup/Brightroom's EditingCanvas
// (EditingCanvasStroke.swift) — the masking/image-editing concerns are dropped;
// this operates purely on `[CGPoint]`. Two stages run in order:
//   raw coalesced points
//     → StrokeStabilizer  (velocity-aware exponential lag — the "feel")
//     → spline smoother   (streaming cubic Bézier / Catmull-Rom / moving avg)
//     → uniformly resampled points
// Callers then decimate the output into fixed-spacing brush stamps.

struct StrokeSmoother {

  private var configuration = InkSmoothing()
  private var stabilizer = StrokeStabilizer()
  private var bezier = BezierStrokeSmoother()
  private var catmullRom = CatmullRomStrokeSmoother()
  private var movingAverage = MovingAverageStrokeSmoother()

  mutating func configure(_ configuration: InkSmoothing) {
    guard self.configuration != configuration else { return }
    self.configuration = configuration
    reset()
  }

  mutating func begin(at point: CGPoint) {
    reset()
    stabilizer.begin(at: point)

    switch configuration.algorithm {
    case .raw:
      break
    case .bezier:
      bezier.begin(at: point)
    case .catmullRom:
      catmullRom.begin(at: point)
    case .movingAverage:
      movingAverage.begin(at: point)
    }
  }

  mutating func append(_ inputPoints: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    let prepared = stabilizer.append(
      inputPoints,
      strength: configuration.strength,
      sampleDistance: sampleDistance
    )
    return appendPrepared(prepared, sampleDistance: sampleDistance)
  }

  mutating func finish(at point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    let prepared = stabilizer.finish(
      at: point,
      strength: configuration.strength,
      sampleDistance: sampleDistance
    )
    guard let endPoint = prepared.last else {
      reset()
      return []
    }

    var output = appendPrepared(Array(prepared.dropLast()), sampleDistance: sampleDistance)
    output += finishPrepared(at: endPoint, sampleDistance: sampleDistance)
    reset()
    return output
  }

  mutating func reset() {
    stabilizer.reset()
    bezier.reset()
    catmullRom.reset()
    movingAverage.reset()
  }

  private mutating func appendPrepared(_ points: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return points
    case .bezier:
      return bezier.append(points, sampleDistance: sampleDistance)
    case .catmullRom:
      return catmullRom.append(points, sampleDistance: sampleDistance)
    case .movingAverage:
      return movingAverage.append(points, sampleDistance: sampleDistance)
    }
  }

  private mutating func finishPrepared(at point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return [point]
    case .bezier:
      return bezier.finish(at: point, sampleDistance: sampleDistance)
    case .catmullRom:
      return catmullRom.finish(at: point, sampleDistance: sampleDistance)
    case .movingAverage:
      return movingAverage.finish(at: point, sampleDistance: sampleDistance)
    }
  }
}

// MARK: - Stabilizer

/// Velocity-aware exponential lag filter (think Procreate "Streamline"): the
/// stabilized point trails the finger by a strength-scaled fraction, catching up
/// faster on fast strokes.
struct StrokeStabilizer {

  private var stabilizedPoint: CGPoint?

  mutating func begin(at point: CGPoint) {
    reset()
    stabilizedPoint = point
  }

  mutating func append(_ inputPoints: [CGPoint], strength: Double, sampleDistance: CGFloat) -> [CGPoint] {
    inputPoints.map { append($0, strength: strength, sampleDistance: sampleDistance) }
  }

  mutating func finish(at point: CGPoint, strength: Double, sampleDistance: CGFloat) -> [CGPoint] {
    let stabilizedEnd = append(point, strength: strength, sampleDistance: sampleDistance)
    guard strength > 0.001 else {
      reset()
      return [point]
    }

    // The lagged endpoint trails the real finger; append a straight catch-up
    // tail so the stroke actually ends where the finger lifted.
    let catchUpPoints = LinearSegment(start: stabilizedEnd, end: point)
      .sampledPoints(maxSegmentLength: sampleDistance)
      .dropFirst()

    reset()
    return [stabilizedEnd] + Array(catchUpPoints)
  }

  mutating func reset() {
    stabilizedPoint = nil
  }

  private mutating func append(_ point: CGPoint, strength: Double, sampleDistance: CGFloat) -> CGPoint {
    guard let currentPoint = stabilizedPoint else {
      stabilizedPoint = point
      return point
    }

    let clampedStrength = min(max(CGFloat(strength), 0), 1)
    guard clampedStrength > 0.001 else {
      stabilizedPoint = point
      return point
    }

    let distance = currentPoint.distance(to: point)
    let lagDistance = max(sampleDistance, 1) * (2 + clampedStrength * 24)
    let distanceResponse = min(distance / lagDistance, 1)
    let baseResponse = max(0.035, 1 - clampedStrength * 0.965)
    let response = min(max(baseResponse + distanceResponse * 0.16, 0.035), 1)
    let nextPoint = currentPoint.interpolate(to: point, progress: response)
    stabilizedPoint = nextPoint
    return nextPoint
  }
}

// MARK: - Bezier (default)

/// Streaming cubic Bézier through a 5-point sliding window; segment endpoints are
/// the midpoint of the last two raw points, giving C¹ continuity between segments.
struct BezierStrokeSmoother {

  private var controlPointIndex = 0
  private var points = Array(repeating: CGPoint.zero, count: 5)

  mutating func begin(at point: CGPoint) {
    reset()
    points[0] = point
  }

  mutating func append(_ inputPoints: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    inputPoints.flatMap { append($0, sampleDistance: sampleDistance) }
  }

  mutating func finish(at point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    var output = append(point, sampleDistance: sampleDistance)

    switch controlPointIndex {
    case 0:
      break
    case 1:
      output.append(points[1])
    case 2:
      output += QuadraticBezierSegment(start: points[0], control: points[1], end: points[2])
        .sampledPoints(maxSegmentLength: sampleDistance)
    case 3:
      output += CubicBezierSegment(start: points[0], control1: points[1], control2: points[2], end: points[3])
        .sampledPoints(maxSegmentLength: sampleDistance)
    default:
      break
    }

    reset()
    return output
  }

  mutating func reset() {
    controlPointIndex = 0
    points = Array(repeating: CGPoint.zero, count: 5)
  }

  private mutating func append(_ point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    controlPointIndex += 1
    points[controlPointIndex] = point

    guard controlPointIndex == 4 else { return [] }

    points[3] = points[2].midpoint(to: points[4])

    let smoothed = CubicBezierSegment(
      start: points[0],
      control1: points[1],
      control2: points[2],
      end: points[3]
    )
    .sampledPoints(maxSegmentLength: sampleDistance)

    points[0] = points[3]
    points[1] = points[4]
    controlPointIndex = 1

    return smoothed
  }
}

// MARK: - Catmull-Rom

struct CatmullRomStrokeSmoother {

  private var points: [CGPoint] = []

  mutating func begin(at point: CGPoint) {
    reset()
    points = [point]
  }

  mutating func append(_ inputPoints: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    inputPoints.flatMap { append($0, sampleDistance: sampleDistance) }
  }

  mutating func finish(at point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    var output = append(point, sampleDistance: sampleDistance)

    switch points.count {
    case 0, 1:
      output.append(point)
    case 2:
      output += LinearSegment(start: points[0], end: points[1])
        .sampledPoints(maxSegmentLength: sampleDistance)
    default:
      if let lastPoint = points.last {
        points.append(lastPoint)
        while points.count >= 4 {
          output += emitSegment(sampleDistance: sampleDistance)
        }
      }
    }

    reset()
    return output
  }

  mutating func reset() {
    points.removeAll(keepingCapacity: true)
  }

  private mutating func append(_ point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    points.append(point)
    guard points.count >= 4 else { return [] }
    return emitSegment(sampleDistance: sampleDistance)
  }

  private mutating func emitSegment(sampleDistance: CGFloat) -> [CGPoint] {
    let segment = CatmullRomSegment(
      point0: points[0],
      point1: points[1],
      point2: points[2],
      point3: points[3]
    )
    points.removeFirst()
    return segment.sampledPoints(maxSegmentLength: sampleDistance)
  }
}

// MARK: - Moving Average

struct MovingAverageStrokeSmoother {

  private let windowSize = 4
  private var recentPoints: [CGPoint] = []

  mutating func begin(at point: CGPoint) {
    reset()
    recentPoints = [point]
  }

  mutating func append(_ inputPoints: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    inputPoints.flatMap { append($0) }
  }

  mutating func finish(at point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    var output = append(point)
    if (output.last?.distance(to: point) ?? .greatestFiniteMagnitude) > 0.5 {
      output.append(point)
    }
    reset()
    return output
  }

  mutating func reset() {
    recentPoints.removeAll(keepingCapacity: true)
  }

  private mutating func append(_ point: CGPoint) -> [CGPoint] {
    recentPoints.append(point)
    if recentPoints.count > windowSize {
      recentPoints.removeFirst(recentPoints.count - windowSize)
    }
    return [averagePoint]
  }

  private var averagePoint: CGPoint {
    let total = recentPoints.reduce(CGPoint.zero) { partial, point in
      CGPoint(x: partial.x + point.x, y: partial.y + point.y)
    }
    let count = CGFloat(max(recentPoints.count, 1))
    return CGPoint(x: total.x / count, y: total.y / count)
  }
}

// MARK: - Segments (uniform resampling)

struct LinearSegment {
  var start: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let length = start.distance(to: end)
    let count = max(Int(ceil(length / max(maxSegmentLength, 1))), 1)
    return (0...count).map { index in
      start.interpolate(to: end, progress: CGFloat(index) / CGFloat(count))
    }
  }
}

struct CubicBezierSegment {
  var start: CGPoint
  var control1: CGPoint
  var control2: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let estimatedLength = start.distance(to: control1)
      + control1.distance(to: control2)
      + control2.distance(to: end)
    let count = max(Int(ceil(estimatedLength / max(maxSegmentLength, 1))), 4)
    return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t
    return CGPoint(
      x: start.x * a + control1.x * b + control2.x * c + end.x * d,
      y: start.y * a + control1.y * b + control2.y * c + end.y * d
    )
  }
}

struct CatmullRomSegment {
  var point0: CGPoint
  var point1: CGPoint
  var point2: CGPoint
  var point3: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let count = max(Int(ceil(point1.distance(to: point2) / max(maxSegmentLength, 1))), 4)
    return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let t2 = t * t
    let t3 = t2 * t
    return CGPoint(
      x: Self.interpolate(point0.x, point1.x, point2.x, point3.x, t: t, t2: t2, t3: t3),
      y: Self.interpolate(point0.y, point1.y, point2.y, point3.y, t: t, t2: t2, t3: t3)
    )
  }

  private static func interpolate(
    _ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat,
    t: CGFloat, t2: CGFloat, t3: CGFloat
  ) -> CGFloat {
    let base = 2 * p1
    let linear = (p2 - p0) * t
    let quadratic = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
    let cubic = (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    return 0.5 * (base + linear + quadratic + cubic)
  }
}

struct QuadraticBezierSegment {
  var start: CGPoint
  var control: CGPoint
  var end: CGPoint

  func sampledPoints(maxSegmentLength: CGFloat) -> [CGPoint] {
    let estimatedLength = start.distance(to: control) + control.distance(to: end)
    let count = max(Int(ceil(estimatedLength / max(maxSegmentLength, 1))), 2)
    return (0...count).map { point(at: CGFloat($0) / CGFloat(count)) }
  }

  private func point(at t: CGFloat) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT
    let b = 2 * oneMinusT * t
    let c = t * t
    return CGPoint(
      x: start.x * a + control.x * b + end.x * c,
      y: start.y * a + control.y * b + end.y * c
    )
  }
}

// MARK: - CGPoint helpers

extension CGPoint {
  func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }

  func midpoint(to point: CGPoint) -> CGPoint {
    CGPoint(x: (x + point.x) / 2, y: (y + point.y) / 2)
  }

  func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(x: x + (point.x - x) * progress, y: y + (point.y - y) * progress)
  }
}
