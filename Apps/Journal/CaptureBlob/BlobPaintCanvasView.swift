import Observation
import SwiftUI
import UIKit

// MARK: - Controller

/// Owns the live and committed layers for `BlobPaintCanvasView`.
///
/// The live layer is already the authored geometry. When the finger lifts, the
/// current live layer is committed without a second fitting pass so the visible
/// shape does not move after being drawn.
@MainActor
@Observable
final class BlobPaintCanvas {

  private(set) var layers: [BlobLayer] = []
  private(set) var liveLayer: BlobLayer?

  var width: Double = 180
  var selectedStyleIndex: Int = 0
  var canvasSize: CGSize = .zero

  @ObservationIgnored private var smoother = BlobCenterlineSmoother()
  @ObservationIgnored private var originTimestamp: TimeInterval?
  @ObservationIgnored private var livePoints: [BlobPoint] = []
  @ObservationIgnored private var liveStyle: BlobGradientStyle = BlobGradientStyle.presets[0]
  @ObservationIgnored private var lastEmittedTime: TimeInterval = 0
  @ObservationIgnored private var lastEmittedLocation: CGPoint = .zero

  var isEmpty: Bool {
    layers.isEmpty
  }

  var duration: TimeInterval {
    layers.last?.points.last?.time ?? 0
  }

  private var selectedStyle: BlobGradientStyle {
    let presets = BlobGradientStyle.presets
    guard presets.indices.contains(selectedStyleIndex) else { return presets[0] }
    return presets[selectedStyleIndex]
  }

  func begin(_ sample: BlobTouchSample) {
    smoother.begin(at: sample.location)
    liveStyle = selectedStyle

    let time = relativeTime(sample.timestamp)
    livePoints = [BlobPoint(x: sample.location.x, y: sample.location.y, time: time)]
    lastEmittedTime = time
    lastEmittedLocation = sample.location
    liveLayer = BlobLayer(points: livePoints, width: width, style: liveStyle)
  }

  func append(_ samples: [BlobTouchSample]) {
    guard let last = samples.last else { return }
    appendLive(samples, reaching: relativeTime(last.timestamp))
  }

  func end(_ sample: BlobTouchSample) {
    appendLive([sample], reaching: relativeTime(sample.timestamp))
    if let liveLayer, liveLayer.points.isEmpty == false {
      layers.append(liveLayer)
    }
    resetLive()
  }

  func cancel() {
    resetLive()
  }

  func undo() {
    guard layers.isEmpty == false else { return }
    layers.removeLast()
  }

  func clear() {
    layers.removeAll()
    originTimestamp = nil
    resetLive()
  }

  func makePainting() -> BlobPainting? {
    guard layers.isEmpty == false else { return nil }
    return BlobPainting(layers: layers, canvasSize: canvasSize, duration: duration)
  }

  private func relativeTime(_ timestamp: TimeInterval) -> TimeInterval {
    let origin = originTimestamp ?? {
      originTimestamp = timestamp
      return timestamp
    }()
    return timestamp - origin
  }

  private func appendLive(_ samples: [BlobTouchSample], reaching target: TimeInterval) {
    let smoothed = smoother.append(samples, width: CGFloat(width))
    let timed = assignTimes(to: smoothed, reaching: target)
    guard timed.isEmpty == false else { return }
    livePoints += timed
    liveLayer = BlobLayer(points: livePoints, width: width, style: liveStyle)
  }

  private func assignTimes(to points: [CGPoint], reaching target: TimeInterval) -> [BlobPoint] {
    guard points.isEmpty == false else { return [] }

    var cumulative: [CGFloat] = []
    var total: CGFloat = 0
    var previous = lastEmittedLocation
    for point in points {
      total += previous.distance(to: point)
      cumulative.append(total)
      previous = point
    }

    let start = lastEmittedTime
    let span = max(target - start, 0)
    let count = points.count

    let timed = points.enumerated().map { index, point -> BlobPoint in
      let fraction = total > 0 ? Double(cumulative[index] / total) : Double(index + 1) / Double(count)
      return BlobPoint(x: point.x, y: point.y, time: start + span * fraction)
    }

    lastEmittedTime = timed.last?.time ?? start
    lastEmittedLocation = points.last ?? lastEmittedLocation
    return timed
  }

  private func resetLive() {
    smoother.reset()
    livePoints = []
    liveLayer = nil
  }
}

// MARK: - Canvas view

/// Interactive surface for drawing translucent gradient blobs.
public struct BlobPaintCanvasView: View {

  @State private var canvas = BlobPaintCanvas()

  private let onExport: (@MainActor @Sendable (BlobPainting) -> Void)?

  public init(
    onExport: (@MainActor @Sendable (BlobPainting) -> Void)? = nil
  ) {
    self.onExport = onExport
  }

  public var body: some View {
    ZStack {
      Color(red: 0.94, green: 0.93, blue: 0.90)
        .ignoresSafeArea()

      BlobPaintingRenderer(layers: canvas.layers, liveLayer: canvas.liveLayer)
        .ignoresSafeArea()

      BlobInputView(canvas: canvas)
        .ignoresSafeArea()
    }
    .overlay(alignment: .bottom) {
      controlBar
        .padding(.horizontal)
        .padding(.bottom, 10)
    }
  }

  private var controlBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        ForEach(BlobGradientStyle.presets.indices, id: \.self) { index in
          BlobStyleButton(
            style: BlobGradientStyle.presets[index],
            isSelected: canvas.selectedStyleIndex == index
          ) {
            canvas.selectedStyleIndex = index
          }
        }

        Spacer(minLength: 8)

        Button {
          canvas.undo()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .disabled(canvas.isEmpty)

        Button(role: .destructive) {
          canvas.clear()
        } label: {
          Image(systemName: "trash")
        }
        .disabled(canvas.isEmpty)

        if let onExport {
          Button {
            if let painting = canvas.makePainting() {
              onExport(painting)
            }
          } label: {
            Image(systemName: "checkmark")
              .fontWeight(.semibold)
          }
          .disabled(canvas.isEmpty)
        }
      }

      Slider(
        value: Binding(get: { canvas.width }, set: { canvas.width = $0 }),
        in: 80...260
      )
    }
    .font(.body)
    .buttonStyle(.bordered)
    .padding(12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

private struct BlobStyleButton: View {
  let style: BlobGradientStyle
  let isSelected: Bool
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(gradient)
        .frame(width: 30, height: 30)
        .overlay {
          Circle()
            .strokeBorder(isSelected ? Color.primary : Color.white.opacity(0.72), lineWidth: isSelected ? 3 : 1.5)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(style.name))
  }

  private var gradient: LinearGradient {
    LinearGradient(
      colors: [
        style.startColor.color,
        style.middleColor?.color ?? style.endColor.color,
        style.endColor.color,
      ],
      startPoint: style.startPoint.unitPoint,
      endPoint: style.endPoint.unitPoint
    )
  }
}

// MARK: - Smoothing

private struct BlobCenterlineSmoother {

  private var filteredPoint: CGPoint?
  private var lastEmittedPoint: CGPoint?
  private var previousSample: BlobTouchSample?
  private var filteredVelocity: CGFloat = 0

  mutating func begin(at point: CGPoint) {
    reset()
    filteredPoint = point
    lastEmittedPoint = point
  }

  mutating func append(_ samples: [BlobTouchSample], width: CGFloat) -> [CGPoint] {
    samples.flatMap { append($0, width: width) }
  }

  mutating func reset() {
    filteredPoint = nil
    lastEmittedPoint = nil
    previousSample = nil
    filteredVelocity = 0
  }

  private mutating func append(_ sample: BlobTouchSample, width: CGFloat) -> [CGPoint] {
    guard let lastEmittedPoint else {
      begin(at: sample.location)
      previousSample = sample
      return [sample.location]
    }

    updateVelocity(with: sample)
    let filteredLocation = smoothedLocation(to: sample.location)
    let distance = lastEmittedPoint.distance(to: filteredLocation)
    let spacing = anchorSpacing(width: width)
    guard distance >= spacing else { return [] }

    self.lastEmittedPoint = filteredLocation
    return [filteredLocation]
  }

  private mutating func updateVelocity(with sample: BlobTouchSample) {
    defer { previousSample = sample }
    guard let previousSample else { return }

    let elapsed = max(sample.timestamp - previousSample.timestamp, 1.0 / 240.0)
    let velocity = previousSample.location.distance(to: sample.location) / CGFloat(elapsed)
    filteredVelocity += (velocity - filteredVelocity) * 0.18
  }

  private mutating func smoothedLocation(to location: CGPoint) -> CGPoint {
    guard let filteredPoint else {
      self.filteredPoint = location
      return location
    }

    let speed = smoothstep(edge0: 160, edge1: 1_500, value: filteredVelocity)
    let response = min(0.06 + speed * 0.20, 0.26)
    let nextPoint = filteredPoint.interpolate(to: location, progress: response)
    self.filteredPoint = nextPoint
    return nextPoint
  }

  private func anchorSpacing(width: CGFloat) -> CGFloat {
    let speed = smoothstep(edge0: 180, edge1: 1_600, value: filteredVelocity)
    return max(width * (0.045 + speed * 0.045), 8)
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}

// MARK: - UIKit input bridge

struct BlobTouchSample {
  var location: CGPoint
  var timestamp: TimeInterval
}

private struct BlobInputView: UIViewRepresentable {
  let canvas: BlobPaintCanvas

  func makeUIView(context: Context) -> InputView {
    let view = InputView()
    view.backgroundColor = .clear
    view.onLayout = { size in canvas.canvasSize = size }

    let recognizer = BlobDrawingGestureRecognizer(target: nil, action: nil)
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

private final class BlobDrawingGestureRecognizer: UIGestureRecognizer {

  var onBegin: (@MainActor (BlobTouchSample) -> Void)?
  var onMove: (@MainActor ([BlobTouchSample]) -> Void)?
  var onEnd: (@MainActor (BlobTouchSample) -> Void)?
  var onCancel: (@MainActor () -> Void)?

  private let directTouchDrawingThreshold: CGFloat = 8
  private weak var activeTouch: UITouch?
  private var activeTouchType: UITouch.TouchType?
  private var initialPoint: CGPoint?
  private var initialTimestamp: TimeInterval?
  private var didBeginDrawing = false

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue),
      NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]
  }

  override func reset() {
    super.reset()
    activeTouch = nil
    activeTouchType = nil
    initialPoint = nil
    initialTimestamp = nil
    didBeginDrawing = false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard activeTouch == nil else {
      cancelLayer()
      return
    }
    guard
      event.allTouches?.count == 1,
      touches.count == 1,
      let touch = touches.first
    else {
      state = .failed
      return
    }
    activeTouch = touch
    activeTouchType = touch.type
    initialPoint = touch.location(in: view)
    initialTimestamp = touch.timestamp
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      event.allTouches?.count == 1,
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      cancelLayer()
      return
    }

    let currentPoint = activeTouch.location(in: view)
    guard didBeginDrawing || shouldBeginDrawing(at: currentPoint) else { return }

    beginDrawingIfNeeded(fallback: BlobTouchSample(location: currentPoint, timestamp: activeTouch.timestamp))
    let coalesced = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
    onMove?(coalesced.map { BlobTouchSample(location: $0.location(in: view), timestamp: $0.timestamp) })
    if state == .began { return }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let activeTouch, touches.contains(where: { $0 === activeTouch }) else { return }
    let end = BlobTouchSample(location: activeTouch.location(in: view), timestamp: activeTouch.timestamp)
    beginDrawingIfNeeded(fallback: end)
    onEnd?(end)
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    cancelLayer()
  }

  private func shouldBeginDrawing(at point: CGPoint) -> Bool {
    guard activeTouchType != .pencil, let initialPoint else { return true }
    return initialPoint.distance(to: point) >= directTouchDrawingThreshold
  }

  private func beginDrawingIfNeeded(fallback: BlobTouchSample) {
    guard didBeginDrawing == false else { return }
    didBeginDrawing = true
    state = .began
    if let initialPoint, let initialTimestamp {
      onBegin?(BlobTouchSample(location: initialPoint, timestamp: initialTimestamp))
    } else {
      onBegin?(fallback)
    }
  }

  private func cancelLayer() {
    guard didBeginDrawing else {
      state = .failed
      return
    }
    onCancel?()
    state = .cancelled
  }
}
