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
  var width: Double = 14
  var smoothing = InkSmoothing()

  /// Point size of the drawing surface, kept in sync by the input view's layout.
  var canvasSize: CGSize = .zero

  @ObservationIgnored private var smoother = StrokeSmoother()
  /// `UITouch.timestamp` of the very first point, the zero of the shared timeline.
  /// Persists across strokes (so pen-up gaps replay) until `clear()`.
  @ObservationIgnored private var originTimestamp: TimeInterval?
  @ObservationIgnored private var livePoints: [DoodlePoint] = []
  @ObservationIgnored private var lastEmittedTime: TimeInterval = 0
  @ObservationIgnored private var lastEmittedLocation: CGPoint = .zero

  init() {}

  var isEmpty: Bool { strokes.isEmpty }
  var duration: TimeInterval { strokes.last?.points.last?.time ?? 0 }

  /// Half the stamp spacing, floored — the resolution the smoother resamples to.
  /// Matches the old Metal canvas's near-constant `sampleDistance`.
  private var sampleDistance: CGFloat { max(CGFloat(width) * 0.025, 2) }

  // MARK: Input (driven by DoodleInputView)

  func begin(_ point: TimedPoint) {
    smoother.configure(smoothing)
    smoother.begin(at: point.location)

    let time = relativeTime(point.timestamp)
    livePoints = [DoodlePoint(x: point.location.x, y: point.location.y, time: time)]
    lastEmittedTime = time
    lastEmittedLocation = point.location
    liveStroke = DoodleStroke(points: livePoints, width: width)
  }

  func append(_ points: [TimedPoint]) {
    guard let last = points.last else { return }
    let smoothed = smoother.append(points.map(\.location), sampleDistance: sampleDistance)
    let timed = assignTimes(to: smoothed, reaching: relativeTime(last.timestamp))
    guard timed.isEmpty == false else { return }
    livePoints += timed
    liveStroke = DoodleStroke(points: livePoints, width: width)
  }

  func end(_ point: TimedPoint) {
    let smoothed = smoother.finish(at: point.location, sampleDistance: sampleDistance)
    let timed = assignTimes(to: smoothed, reaching: relativeTime(point.timestamp))
    livePoints += timed

    if livePoints.isEmpty == false {
      strokes.append(DoodleStroke(points: livePoints, width: width))
    }
    resetLive()
  }

  func cancel() {
    smoother.reset()
    resetLive()
  }

  // MARK: Editing

  func undo() {
    guard strokes.isEmpty == false else { return }
    strokes.removeLast()
  }

  func clear() {
    strokes.removeAll()
    originTimestamp = nil
    resetLive()
  }

  func makeDrawing() -> DoodleDrawing? {
    guard strokes.isEmpty == false else { return nil }
    return DoodleDrawing(strokes: strokes, canvasSize: canvasSize, duration: duration)
  }

  // MARK: Timing

  private func relativeTime(_ timestamp: TimeInterval) -> TimeInterval {
    let origin = originTimestamp ?? {
      originTimestamp = timestamp
      return timestamp
    }()
    return timestamp - origin
  }

  /// Distributes the interval `[lastEmittedTime, target]` across the freshly
  /// smoothed points by arc length, so each point gets a monotonically increasing
  /// timestamp that tracks the real drawing speed. Smoothed points lag the raw
  /// input, so the mapping is approximate — fine for replay.
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

    let timed = smoothed.enumerated().map { index, point -> DoodlePoint in
      let fraction = total > 0 ? Double(cumulative[index] / total) : Double(index + 1) / Double(count)
      return DoodlePoint(x: point.x, y: point.y, time: start + span * fraction)
    }

    lastEmittedTime = timed.last?.time ?? start
    lastEmittedLocation = smoothed.last ?? lastEmittedLocation
    return timed
  }

  private func resetLive() {
    livePoints = []
    liveStroke = nil
  }
}

// MARK: - Canvas View

/// A self-contained doodle surface: a single theme-colored ink, a width slider,
/// undo, clear, replay, and (optional) export. The ink is `inkColor`, applied at
/// draw time, so changing the app theme re-tints everything — including a doodle
/// drawn earlier. Smooth ink via the ported Brightroom smoothing.
public struct DoodleCanvasView: View {

  @State private var canvas = DoodleCanvas()
  /// Non-nil while a replay is animating; the value is the replay's start time.
  @State private var replayStart: Date?

  private let inkColor: Color
  private let onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)?

  public init(
    inkColor: Color,
    onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)? = nil
  ) {
    self.inkColor = inkColor
    self.onExport = onExport
  }

  /// Gaps between points longer than this are clamped during replay, so long
  /// pauses (mostly the pen-up time between strokes) collapse to a short beat
  /// instead of dead time. The stored timestamps stay faithful — this only shapes
  /// playback.
  private static let replayMaxGap: TimeInterval = 0.35

  public var body: some View {
    // Read in `body` so Observation tracks edits and the canvas re-renders.
    let strokes = canvas.strokes
    let live = canvas.liveStroke

    ZStack {
      inkLayer(strokes: strokes, live: live)
        .ignoresSafeArea()

      DoodleInputView(canvas: canvas)
        .ignoresSafeArea()
        // Lock input out while a replay is animating so a stray touch can't
        // splice a new stroke into the playback.
        .allowsHitTesting(replayStart == nil)
    }
    .overlay(alignment: .bottom) {
      controlBar
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
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
      DoodleStrokesView(strokes: strokes, liveStroke: live, inkColor: inkColor, revealedTime: nil)
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
    view.onLayout = { size in canvas.canvasSize = size }

    let recognizer = DrawingGestureRecognizer(target: nil, action: nil)
    recognizer.onBegin = { canvas.begin($0) }
    recognizer.onMove = { canvas.append($0) }
    recognizer.onEnd = { canvas.end($0) }
    recognizer.onCancel = { canvas.cancel() }
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
        return DoodlePoint(x: point.x, y: point.y, time: clock)
      }
      return DoodleStroke(points: points, width: stroke.width)
    }
  }
}
