import UIKit

/// A touch location paired with its `UITouch.timestamp` (seconds since boot,
/// monotonic). Timestamps flow all the way into the stored model so a doodle can
/// be replayed at the speed it was drawn.
struct TimedPoint {
  var location: CGPoint
  var timestamp: TimeInterval
}

/// Single-touch drawing recognizer ported from Brightroom's
/// `_EditingCanvasDrawingGestureRecognizer`. Consumes coalesced touches for
/// high-frequency input, draws Pencil immediately, and requires an 8pt movement
/// slop before a finger starts a stroke. Touch-down is still reported
/// immediately for tactile feedback. A second touch cancels the stroke.
final class DrawingGestureRecognizer: UIGestureRecognizer {

  var onTouchDown: (@MainActor (TimedPoint) -> Void)?
  var onBegin: (@MainActor (TimedPoint) -> Void)?
  var onMove: (@MainActor ([TimedPoint]) -> Void)?
  var onEnd: (@MainActor (TimedPoint) -> Void)?
  var onCancel: (@MainActor () -> Void)?
  var onTouchCancel: (@MainActor () -> Void)?

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
      cancelStroke()
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
    let initialPoint = touch.location(in: view)
    let initialTimestamp = touch.timestamp
    self.initialPoint = initialPoint
    self.initialTimestamp = initialTimestamp
    onTouchDown?(TimedPoint(location: initialPoint, timestamp: initialTimestamp))
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard
      event.allTouches?.count == 1,
      let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else {
      cancelStroke()
      return
    }

    let currentPoint = activeTouch.location(in: view)
    guard didBeginDrawing || shouldBeginDrawing(at: currentPoint) else { return }

    beginDrawingIfNeeded(fallback: TimedPoint(location: currentPoint, timestamp: activeTouch.timestamp))
    let coalesced = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
    onMove?(coalesced.map { TimedPoint(location: $0.location(in: view), timestamp: $0.timestamp) })
    if state == .began { return }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let activeTouch, touches.contains(where: { $0 === activeTouch }) else { return }
    let end = TimedPoint(location: activeTouch.location(in: view), timestamp: activeTouch.timestamp)
    beginDrawingIfNeeded(fallback: end)
    onEnd?(end)
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    cancelStroke()
  }

  private func shouldBeginDrawing(at point: CGPoint) -> Bool {
    guard activeTouchType != .pencil, let initialPoint else { return true }
    return initialPoint.distance(to: point) >= directTouchDrawingThreshold
  }

  private func beginDrawingIfNeeded(fallback: TimedPoint) {
    guard didBeginDrawing == false else { return }
    didBeginDrawing = true
    state = .began
    if let initialPoint, let initialTimestamp {
      onBegin?(TimedPoint(location: initialPoint, timestamp: initialTimestamp))
    } else {
      onBegin?(fallback)
    }
  }

  private func cancelStroke() {
    guard didBeginDrawing else {
      onTouchCancel?()
      state = .failed
      return
    }
    onCancel?()
    state = .cancelled
  }
}
