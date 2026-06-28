import Observation
import SwiftUI
import UIKit

// MARK: - Controller

/// Owns the live and committed strokes for a `DoodleCanvasView`. Strokes are
/// stored as colorless vector geometry with per-point timestamps; the view tints
/// them with the current theme color at draw time and can replay them.
@MainActor
@Observable
final class DoodleCanvas {

  /// Committed strokes, oldest first. Read in the view's `body` so the canvas
  /// re-renders on every edit.
  private(set) var strokes: [DoodleStroke] = []
  /// The stroke currently being drawn, or `nil` when idle.
  private(set) var liveStroke: DoodleStroke?

  /// Brush width in points. The doodle is a single theme color, so width is the
  /// only brush control.
  var width: Double = 3

  /// Point size of the drawing surface, kept in sync by the input view's layout.
  var canvasSize: CGSize = .zero

  @ObservationIgnored private var smoother = StrokeSmoother()
  /// `UITouch.timestamp` of the very first point, the zero of the shared timeline.
  /// Persists across strokes (so pen-up gaps replay) until `clear()`.
  @ObservationIgnored private var originTimestamp: TimeInterval?
  /// Offset applied when appending new strokes to an existing drawing.
  @ObservationIgnored private var timelineOffset: TimeInterval = 0
  @ObservationIgnored private var livePoints: [DoodlePoint] = []
  @ObservationIgnored private var lastEmittedTime: TimeInterval = 0
  @ObservationIgnored private var lastEmittedLocation: CGPoint = .zero
  @ObservationIgnored private var lastEmittedWidth: Double = 0
  @ObservationIgnored private let drawingHaptics = DoodleDrawingHaptics()

  init(drawing: DoodleDrawing? = nil) {
    guard let drawing, drawing.isEmpty == false else { return }
    strokes = drawing.strokes
    canvasSize = drawing.canvasSize
    timelineOffset = drawing.duration
    lastEmittedTime = drawing.duration

    if let lastStroke = drawing.strokes.last {
      width = lastStroke.width
      lastEmittedWidth = lastStroke.points.last?.width ?? lastStroke.width
      lastEmittedLocation = lastStroke.points.last?.location ?? .zero
    }
  }

  var isEmpty: Bool { strokes.isEmpty }
  var duration: TimeInterval { strokes.last?.points.last?.time ?? 0 }

  /// The centerline resampling resolution for saved points.
  ///
  /// The renderer turns these points back into spline knots, so storing coarse
  /// spacing produces an opinionated curve and avoids preserving small hand
  /// jitter as authored geometry.
  private var sampleDistance: CGFloat { max(CGFloat(width) * 0.20, 6) }

  // MARK: Input (driven by DoodleInputView)

  func touchDown() {
    drawingHaptics.touchDown()
  }

  func begin(_ point: TimedPoint) {
    smoother.begin(at: point)
    drawingHaptics.begin()

    let time = relativeTime(point.timestamp)
    livePoints = [DoodlePoint(x: point.location.x, y: point.location.y, time: time, width: width)]
    lastEmittedTime = time
    lastEmittedLocation = point.location
    lastEmittedWidth = width
    liveStroke = DoodleStroke(points: livePoints, width: width)
  }

  func append(_ points: [TimedPoint]) {
    guard let last = points.last else { return }
    drawingHaptics.update(speed: hapticSpeed(from: points), timestamp: last.timestamp)
    appendLive(points, reaching: relativeTime(last.timestamp))
  }

  func end(_ point: TimedPoint) {
    // The authored live shape is the saved shape. Do not run a second full-stroke
    // fit or a catch-up tail on lift; those make already-seen curves move.
    appendLive([point], reaching: relativeTime(point.timestamp))
    if livePoints.isEmpty == false {
      strokes.append(DoodleStroke(points: livePoints, width: width))
    }
    drawingHaptics.end()
    resetLive()
  }

  func cancel() {
    drawingHaptics.cancel()
    smoother.reset()
    resetLive()
  }

  func touchCancel() {
    drawingHaptics.cancel()
  }

  // MARK: Editing

  func undo() {
    guard strokes.isEmpty == false else { return }
    strokes.removeLast()
  }

  func clear() {
    strokes.removeAll()
    originTimestamp = nil
    timelineOffset = 0
    drawingHaptics.cancel()
    resetLive()
  }

  func makeDrawing() -> DoodleDrawing? {
    guard strokes.isEmpty == false else { return nil }
    return DoodleDrawing(strokes: strokes, canvasSize: canvasSize, duration: duration)
  }

  func updateCanvasSize(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else {
      canvasSize = size
      return
    }

    guard canvasSize.width > 0, canvasSize.height > 0 else {
      canvasSize = size
      return
    }

    guard abs(canvasSize.width - size.width) > 0.5
      || abs(canvasSize.height - size.height) > 0.5
    else {
      return
    }

    let scaleX = size.width / canvasSize.width
    let scaleY = size.height / canvasSize.height
    let widthScale = (scaleX + scaleY) / 2

    strokes = strokes.map { $0.scaled(x: scaleX, y: scaleY) }
    liveStroke = liveStroke?.scaled(x: scaleX, y: scaleY)
    livePoints = livePoints.map { $0.scaled(x: scaleX, y: scaleY) }
    lastEmittedLocation = lastEmittedLocation.scaled(x: scaleX, y: scaleY)
    lastEmittedWidth *= Double(widthScale)
    width *= Double(widthScale)
    canvasSize = size
  }

  // MARK: Timing

  private func relativeTime(_ timestamp: TimeInterval) -> TimeInterval {
    let origin = originTimestamp ?? {
      originTimestamp = timestamp
      return timestamp
    }()
    return timestamp - origin + timelineOffset
  }

  private func appendLive(_ points: [TimedPoint], reaching target: TimeInterval) {
    let smoothed = smoother.append(points, sampleDistance: sampleDistance)
    let timed = assignTimes(to: smoothed, reaching: target)
    guard timed.isEmpty == false else { return }
    livePoints += timed
    liveStroke = DoodleStroke(points: livePoints, width: width)
  }

  private func hapticSpeed(from points: [TimedPoint]) -> CGFloat {
    guard let last = points.last else { return 0 }

    let previousLocation = points.dropLast().last?.location ?? lastEmittedLocation
    let previousTimestamp = points.dropLast().last?.timestamp ?? absoluteTimestamp(for: lastEmittedTime)
    let elapsed = max(last.timestamp - previousTimestamp, 1.0 / 240.0)
    return previousLocation.distance(to: last.location) / CGFloat(elapsed)
  }

  private func absoluteTimestamp(for relativeTime: TimeInterval) -> TimeInterval {
    guard let originTimestamp else { return relativeTime }
    return originTimestamp + relativeTime - timelineOffset
  }

  /// Distributes the interval `[lastEmittedTime, target]` across freshly smoothed
  /// points by arc length. Width is derived from the local speed on that same
  /// timeline: fast spans thin out, while slow spans keep the brush full.
  private func assignTimes(to smoothed: [CGPoint], reaching target: TimeInterval) -> [DoodlePoint] {
    guard smoothed.isEmpty == false else { return [] }

    var cumulative: [CGFloat] = []
    var total: CGFloat = 0
    var previous = lastEmittedLocation
    for point in smoothed {
      total += previous.distance(to: point)
      cumulative.append(total)
      previous = point
    }

    let start = lastEmittedTime
    let span = max(target - start, 0)
    let count = smoothed.count

    var widthLocation = lastEmittedLocation
    var widthTime = lastEmittedTime
    var widthValue = lastEmittedWidth > 0 ? lastEmittedWidth : width

    let timed = smoothed.enumerated().map { index, point -> DoodlePoint in
      let fraction = total > 0 ? Double(cumulative[index] / total) : Double(index + 1) / Double(count)
      let pointTime = start + span * fraction
      let speed = localSpeed(from: widthLocation, at: widthTime, to: point, at: pointTime)
      let targetWidth = brushWidth(forSpeed: speed)
      let response = widthResponse(forSpeed: speed)
      widthValue += (targetWidth - widthValue) * response
      widthLocation = point
      widthTime = pointTime
      return DoodlePoint(x: point.x, y: point.y, time: pointTime, width: widthValue)
    }

    lastEmittedTime = timed.last?.time ?? start
    lastEmittedLocation = smoothed.last ?? lastEmittedLocation
    lastEmittedWidth = timed.last?.width ?? widthValue
    return timed
  }

  private func localSpeed(
    from previousLocation: CGPoint,
    at previousTime: TimeInterval,
    to location: CGPoint,
    at time: TimeInterval
  ) -> CGFloat {
    let elapsed = max(time - previousTime, 1.0 / 240.0)
    return previousLocation.distance(to: location) / CGFloat(elapsed)
  }

  private func brushWidth(forSpeed speed: CGFloat) -> Double {
    let progress = smoothstep(edge0: 80, edge1: 1_250, value: speed)
    let multiplier = 1.04 - Double(progress) * 0.30
    return max(width * 0.68, width * multiplier, 1)
  }

  private func widthResponse(forSpeed speed: CGFloat) -> Double {
    let progress = smoothstep(edge0: 120, edge1: 1_100, value: speed)
    return 0.16 + Double(progress) * 0.10
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }

  private func resetLive() {
    smoother.reset()
    livePoints = []
    liveStroke = nil
  }
}

// MARK: - Canvas View

/// A self-contained doodle surface: a single theme-colored ink, a width slider,
/// undo, clear, replay, and (optional) export. The ink is `inkColor`, applied at
/// draw time, so changing the app theme re-tints everything — including a doodle
/// drawn earlier. The default ink uses stable incremental smoothing and commits
/// the visible live stroke as-is when the finger lifts.
public struct DoodleCanvasView: View {

  @State private var canvas: DoodleCanvas
  /// Non-nil while a replay is animating; the value is the replay's start time.
  @State private var replayStart: Date?

  private let inkColor: Color
  private let onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)?
  private let onChange: (@MainActor @Sendable (DoodleDrawing?) -> Void)?

  @MainActor
  public init(
    inkColor: Color,
    initialDrawing: DoodleDrawing? = nil,
    onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)? = nil,
    onChange: (@MainActor @Sendable (DoodleDrawing?) -> Void)? = nil
  ) {
    _canvas = State(initialValue: DoodleCanvas(drawing: initialDrawing))
    self.inkColor = inkColor
    self.onExport = onExport
    self.onChange = onChange
  }

  /// Gaps between points longer than this are clamped during replay, so long
  /// pauses (mostly the pen-up time between strokes) collapse to a short beat
  /// instead of dead time. The stored timestamps stay faithful — this only shapes
  /// playback.
  private static let replayMaxGap: TimeInterval = 0.35
  /// Width divided by height for the drawable surface. Matches the journal card
  /// paper proportion so exported doodles share the same portrait geometry.
  private static let aspectRatio: CGFloat = 1 / 1.4144

  public var body: some View {
    // Read in `body` so Observation tracks edits and the canvas re-renders.
    let strokes = canvas.strokes
    let live = canvas.liveStroke

    VStack {
      drawingSurface(strokes: strokes, live: live)
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.thinMaterial, lineWidth: 1)
        }
        .padding(8)

      controlBar
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: strokes) { _, _ in
      onChange?(canvas.makeDrawing())
    }
  }

  private func drawingSurface(strokes: [DoodleStroke], live: DoodleStroke?) -> some View {
    ZStack {
      inkLayer(strokes: strokes, live: live)

      DoodleInputView(canvas: canvas)
        // Lock input out while a replay is animating so a stray touch can't
        // splice a new stroke into the playback.
        .allowsHitTesting(replayStart == nil)
    }
    .clipped()
  }

  @ViewBuilder
  private func inkLayer(strokes: [DoodleStroke], live: DoodleStroke?) -> some View {
    if let replayStart {
      // Re-time the strokes onto a gap-compressed clock for playback; the stored
      // strokes keep their real timestamps.
      let replay = strokes.compressingGaps(maxGap: Self.replayMaxGap)
      let replayDuration = replay.last?.points.last?.time ?? 0
      TimelineView(.animation) { timeline in
        let elapsed = timeline.date.timeIntervalSince(replayStart)
        DoodleStrokesView(strokes: replay, liveStroke: nil, inkColor: inkColor, revealedTime: elapsed)
          .onChange(of: elapsed >= replayDuration) { _, finished in
            if finished { self.replayStart = nil }
          }
      }
    } else {
      DoodleLayeredStrokesView(strokes: strokes, liveStroke: live, inkColor: inkColor)
    }
  }

  private var controlBar: some View {
    HStack(spacing: 16) {
      Slider(
        value: Binding(get: { canvas.width }, set: { canvas.width = $0 }),
        in: 2...48
      )
      .frame(maxWidth: 160)

      Button {
        canvas.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }

      Button {
        replayStart = .init()
      } label: {
        Image(systemName: "play.fill")
      }
      .disabled(canvas.isEmpty || replayStart != nil)

      Button(role: .destructive) {
        canvas.clear()
      } label: {
        Image(systemName: "trash")
      }

      if let onExport {
        Button {
          if let drawing = canvas.makeDrawing() {
            onExport(drawing)
          }
        } label: {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
        }
        .disabled(canvas.isEmpty)
      }
    }
    .padding(12)
    .background(.ultraThinMaterial, in: Capsule())
  }
}

// MARK: - UIKit input bridge

/// A transparent UIView that hosts `DrawingGestureRecognizer` and forwards
/// timestamped points to the canvas. Rendering lives in SwiftUI; this view only
/// captures input (and reports its size so exports match the on-screen geometry).
private struct DoodleInputView: UIViewRepresentable {
  let canvas: DoodleCanvas

  func makeUIView(context: Context) -> InputView {
    let view = InputView()
    view.backgroundColor = .clear
    view.onLayout = { size in canvas.updateCanvasSize(size) }

    let recognizer = DrawingGestureRecognizer(target: nil, action: nil)
    recognizer.onTouchDown = { _ in canvas.touchDown() }
    recognizer.onBegin = { canvas.begin($0) }
    recognizer.onMove = { canvas.append($0) }
    recognizer.onEnd = { canvas.end($0) }
    recognizer.onCancel = { canvas.cancel() }
    recognizer.onTouchCancel = { canvas.touchCancel() }
    view.addGestureRecognizer(recognizer)
    return view
  }

  func updateUIView(_ uiView: InputView, context: Context) {}

  final class InputView: UIView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
      super.layoutSubviews()
      onLayout?(bounds.size)
    }
  }
}

private extension CGPoint {

  func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> CGPoint {
    CGPoint(x: x * scaleX, y: y * scaleY)
  }
}

private extension DoodlePoint {

  func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> DoodlePoint {
    let widthScale = Double((scaleX + scaleY) / 2)
    return DoodlePoint(
      x: x * Double(scaleX),
      y: y * Double(scaleY),
      time: time,
      width: width.map { $0 * widthScale }
    )
  }
}

private extension DoodleStroke {

  func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> DoodleStroke {
    let widthScale = Double((scaleX + scaleY) / 2)
    return DoodleStroke(
      points: points.map { $0.scaled(x: scaleX, y: scaleY) },
      width: width * widthScale
    )
  }
}

// MARK: - Replay timing

extension [DoodleStroke] {

  /// Returns a copy re-timed onto a gap-compressed clock: walking every point in
  /// draw order, any gap to the previous point longer than `maxGap` is clamped to
  /// `maxGap`. Long pauses — almost always the pen-up time between strokes —
  /// collapse to a short beat while the dense within-stroke points (millisecond
  /// gaps) are untouched. Used only to drive replay; stored timestamps are left
  /// faithful to how the doodle was actually drawn.
  func compressingGaps(maxGap: TimeInterval) -> [DoodleStroke] {
    var previousTime: TimeInterval?
    var clock: TimeInterval = 0
    return map { stroke in
      let points = stroke.points.map { point -> DoodlePoint in
        if let previousTime {
          clock += Swift.min(Swift.max(point.time - previousTime, 0), maxGap)
        }
        previousTime = point.time
        return DoodlePoint(x: point.x, y: point.y, time: clock, width: point.width)
      }
      return DoodleStroke(points: points, width: stroke.width)
    }
  }
}
