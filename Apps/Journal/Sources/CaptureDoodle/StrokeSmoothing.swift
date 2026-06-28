import CoreGraphics

// Stroke smoothing ported from FluidGroup/Brightroom's EditingCanvas and then
// pushed toward an Instagram/Procreate-style streamline brush. The masking/image
// editing concerns are dropped; this operates on timestamped touch samples. Two
// stages run in order:
//   raw coalesced points
//     → trajectory filter (keeps the user's large path, removes jitter)
//     → spline smoother   (streaming cubic Bézier)
//     → uniformly resampled points
// Callers render the output as a smooth stroked centerline.

struct StrokeSmoother {

  private static let streamlineStrength: Double = 1.0

  private var streamline = TrajectoryStreamlineFilter()
  private var bezier = BezierStrokeSmoother()

  mutating func begin(at point: TimedPoint) {
    reset()
    streamline.begin(at: point)
    bezier.begin(at: point.location)
  }

  mutating func append(_ inputPoints: [TimedPoint], sampleDistance: CGFloat) -> [CGPoint] {
    let prepared = streamline.append(
      inputPoints,
      strength: Self.streamlineStrength,
      sampleDistance: sampleDistance
    )
    return bezier.append(prepared, sampleDistance: sampleDistance)
  }

  mutating func reset() {
    streamline.reset()
    bezier.reset()
  }
}

// MARK: - Streamline

/// Trajectory-preserving streamline filter.
///
/// Unlike a lazy brush, this does not let the visible ink trail far behind the
/// finger. It keeps the large user-drawn trajectory, drops near-collinear jitter,
/// and emits anchors only when the path has travelled far enough or changed
/// direction enough for the downstream Bézier stage to need a new point.
struct TrajectoryStreamlineFilter {

  private var lastEmittedPoint: CGPoint?
  private var pendingPoint: CGPoint?
  private var previousInput: TimedPoint?
  private var filteredPoint: CGPoint?
  private var filteredVelocity: CGFloat = 0

  mutating func begin(at point: TimedPoint) {
    reset()
    lastEmittedPoint = point.location
    pendingPoint = point.location
    previousInput = point
    filteredPoint = point.location
  }

  mutating func append(_ inputPoints: [TimedPoint], strength: Double, sampleDistance: CGFloat) -> [CGPoint] {
    inputPoints.flatMap { append($0, strength: strength, sampleDistance: sampleDistance) }
  }

  mutating func reset() {
    lastEmittedPoint = nil
    pendingPoint = nil
    previousInput = nil
    filteredPoint = nil
    filteredVelocity = 0
  }

  private mutating func append(_ point: TimedPoint, strength: Double, sampleDistance: CGFloat) -> [CGPoint] {
    guard let lastEmittedPoint else {
      self.lastEmittedPoint = point.location
      pendingPoint = point.location
      previousInput = point
      return [point.location]
    }

    let clampedStrength = min(max(CGFloat(strength), 0), 1)
    guard clampedStrength > 0.001 else {
      self.lastEmittedPoint = point.location
      pendingPoint = point.location
      previousInput = point
      return [point.location]
    }

    updateVelocity(with: point)

    let filteredLocation = smoothedLocation(to: point.location, strength: clampedStrength)
    let distance = lastEmittedPoint.distance(to: filteredLocation)
    let spacing = anchorSpacing(strength: clampedStrength, velocity: filteredVelocity, sampleDistance: sampleDistance)
    let angle = turnAngle(from: lastEmittedPoint, through: pendingPoint ?? lastEmittedPoint, to: filteredLocation)
    pendingPoint = filteredLocation

    guard distance >= spacing || angle >= angleThreshold(strength: clampedStrength) else {
      return []
    }

    self.lastEmittedPoint = filteredLocation
    return [filteredLocation]
  }

  private mutating func updateVelocity(with point: TimedPoint) {
    defer { previousInput = point }
    guard let previousInput else { return }

    let elapsed = max(point.timestamp - previousInput.timestamp, 1.0 / 240.0)
    let velocity = previousInput.location.distance(to: point.location) / CGFloat(elapsed)
    filteredVelocity = filteredVelocity + (velocity - filteredVelocity) * 0.22
  }

  private mutating func smoothedLocation(to location: CGPoint, strength: CGFloat) -> CGPoint {
    guard let filteredPoint else {
      self.filteredPoint = location
      return location
    }

    let speed = smoothstep(edge0: 140, edge1: 1_700, value: filteredVelocity)
    let baseResponse = 0.032 + (1 - strength) * 0.085
    let response = min(baseResponse + speed * 0.095, 0.14)
    let nextPoint = filteredPoint.interpolate(to: location, progress: response)
    self.filteredPoint = nextPoint
    return nextPoint
  }

  private func anchorSpacing(strength: CGFloat, velocity: CGFloat, sampleDistance: CGFloat) -> CGFloat {
    let spacing = max(sampleDistance, 1)
    let slowSpacing = spacing * (3.0 + strength * 4.0)
    let fastSpacing = spacing * (6.0 + strength * 8.5)
    let speed = smoothstep(edge0: 180, edge1: 1_600, value: velocity)
    return slowSpacing + (fastSpacing - slowSpacing) * speed
  }

  private func angleThreshold(strength: CGFloat) -> CGFloat {
    .pi * (0.25 + strength * 0.25)
  }

  private func turnAngle(from start: CGPoint, through middle: CGPoint, to end: CGPoint) -> CGFloat {
    let first = CGVector(dx: middle.x - start.x, dy: middle.y - start.y)
    let second = CGVector(dx: end.x - middle.x, dy: end.y - middle.y)
    let firstLength = max(hypot(first.dx, first.dy), 0.001)
    let secondLength = max(hypot(second.dx, second.dy), 0.001)
    let dot = (first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength)
    return acos(min(max(dot, -1), 1))
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
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

// MARK: - Segments (uniform resampling)

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
