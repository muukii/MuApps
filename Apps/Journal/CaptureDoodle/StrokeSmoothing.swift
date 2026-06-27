import CoreGraphics

// Stroke smoothing ported from FluidGroup/Brightroom's EditingCanvas and then
// pushed toward an Instagram/Procreate-style streamline brush. The masking/image
// editing concerns are dropped; this operates on timestamped touch samples. Two
// stages run in order:
//   raw coalesced points
//     → trajectory filter (keeps the user's large path, removes jitter)
//     → spline smoother   (streaming cubic Bézier / Catmull-Rom / moving avg)
//     → uniformly resampled points
// Callers render the output as a smooth stroked centerline.

struct StrokeSmoother {

  private var configuration = InkSmoothing()
  private var stabilizer = StrokeStabilizer()
  private var streamline = TrajectoryStreamlineFilter()
  private var bezier = BezierStrokeSmoother()
  private var catmullRom = CatmullRomStrokeSmoother()
  private var movingAverage = MovingAverageStrokeSmoother()

  mutating func configure(_ configuration: InkSmoothing) {
    guard self.configuration != configuration else { return }
    self.configuration = configuration
    reset()
  }

  mutating func begin(at point: TimedPoint) {
    reset()
    stabilizer.begin(at: point.location)
    streamline.begin(at: point)

    switch configuration.algorithm {
    case .raw:
      break
    case .streamline:
      bezier.begin(at: point.location)
    case .bezier:
      bezier.begin(at: point.location)
    case .catmullRom:
      catmullRom.begin(at: point.location)
    case .movingAverage:
      movingAverage.begin(at: point.location)
    }
  }

  mutating func append(_ inputPoints: [TimedPoint], sampleDistance: CGFloat) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return inputPoints.map(\.location)
    case .streamline:
      let prepared = streamline.append(
        inputPoints,
        strength: configuration.strength,
        sampleDistance: sampleDistance
      )
      return bezier.append(prepared, sampleDistance: sampleDistance)
    case .bezier, .catmullRom, .movingAverage:
      let prepared = stabilizer.append(
        inputPoints.map(\.location),
        strength: configuration.strength,
        sampleDistance: sampleDistance
      )
      return appendPrepared(prepared, sampleDistance: sampleDistance)
    }
  }

  mutating func finish(at point: TimedPoint, sampleDistance: CGFloat) -> [CGPoint] {
    let prepared: [CGPoint]
    switch configuration.algorithm {
    case .raw:
      prepared = [point.location]
    case .streamline:
      prepared = streamline.finish(
        at: point,
        strength: configuration.strength,
        sampleDistance: sampleDistance
      )
    case .bezier, .catmullRom, .movingAverage:
      prepared = stabilizer.finish(
        at: point.location,
        strength: configuration.strength,
        sampleDistance: sampleDistance
      )
    }

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
    streamline.reset()
    bezier.reset()
    catmullRom.reset()
    movingAverage.reset()
  }

  private mutating func appendPrepared(_ points: [CGPoint], sampleDistance: CGFloat) -> [CGPoint] {
    switch configuration.algorithm {
    case .raw:
      return points
    case .streamline:
      return bezier.append(points, sampleDistance: sampleDistance)
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
    case .streamline:
      return bezier.finish(at: point, sampleDistance: sampleDistance)
    case .bezier:
      return bezier.finish(at: point, sampleDistance: sampleDistance)
    case .catmullRom:
      return catmullRom.finish(at: point, sampleDistance: sampleDistance)
    case .movingAverage:
      return movingAverage.finish(at: point, sampleDistance: sampleDistance)
    }
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

  mutating func finish(at point: TimedPoint, strength: Double, sampleDistance: CGFloat) -> [CGPoint] {
    var output = append(point, strength: strength, sampleDistance: sampleDistance)
    if output.last?.distance(to: point.location) ?? .greatestFiniteMagnitude > max(sampleDistance * 1.5, 1) {
      output += easedCatchUp(to: point.location, sampleDistance: sampleDistance)
    } else if output.isEmpty {
      output.append(point.location)
    }

    reset()
    return output
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
    let baseResponse = 0.075 + (1 - strength) * 0.12
    let response = min(baseResponse + speed * 0.18, 0.28)
    let nextPoint = filteredPoint.interpolate(to: location, progress: response)
    self.filteredPoint = nextPoint
    return nextPoint
  }

  private func anchorSpacing(strength: CGFloat, velocity: CGFloat, sampleDistance: CGFloat) -> CGFloat {
    let spacing = max(sampleDistance, 1)
    let slowSpacing = spacing * (1.4 + strength * 2.2)
    let fastSpacing = spacing * (3.2 + strength * 5.2)
    let speed = smoothstep(edge0: 180, edge1: 1_600, value: velocity)
    return slowSpacing + (fastSpacing - slowSpacing) * speed
  }

  private func angleThreshold(strength: CGFloat) -> CGFloat {
    .pi * (0.14 + strength * 0.20)
  }

  private func turnAngle(from start: CGPoint, through middle: CGPoint, to end: CGPoint) -> CGFloat {
    let first = CGVector(dx: middle.x - start.x, dy: middle.y - start.y)
    let second = CGVector(dx: end.x - middle.x, dy: end.y - middle.y)
    let firstLength = max(hypot(first.dx, first.dy), 0.001)
    let secondLength = max(hypot(second.dx, second.dy), 0.001)
    let dot = (first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength)
    return acos(min(max(dot, -1), 1))
  }

  private func easedCatchUp(to point: CGPoint, sampleDistance: CGFloat) -> [CGPoint] {
    guard let lastEmittedPoint else { return [point] }
    let segment = LinearSegment(start: lastEmittedPoint, end: point)
      .sampledPoints(maxSegmentLength: max(sampleDistance * 2, 1))
    return Array(segment.dropFirst())
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}

// MARK: - Stabilizer

/// Legacy exponential lag filter: the stabilized point trails the finger by a
/// strength-scaled fraction, catching up faster as the distance grows.
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
