import UIKit

/// Single-touch drawing recognizer ported from Brightroom's
/// `_EditingCanvasDrawingGestureRecognizer`. Consumes coalesced touches for
/// high-frequency input, draws Pencil immediately, and requires an 8pt movement
/// slop before a finger starts a stroke. A second touch cancels the stroke.
final class DrawingGestureRecognizer: UIGestureRecognizer {

  var onBegin: ((CGPoint) -> Void)?
  var onMove: (([CGPoint]) -> Void)?
  var onEnd: ((CGPoint) -> Void)?
  var onCancel: (() -> Void)?

  private let directTouchDrawingThreshold: CGFloat = 8
  private weak var activeTouch: UITouch?
  private var activeTouchType: UITouch.TouchType?
  private var initialPoint: CGPoint?
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
    initialPoint = touch.location(in: view)
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

    beginDrawingIfNeeded(at: currentPoint)
    let coalesced = event.coalescedTouches(for: activeTouch) ?? [activeTouch]
    onMove?(coalesced.map { $0.location(in: view) })
    if state == .began { return }
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let activeTouch, touches.contains(where: { $0 === activeTouch }) else { return }
    beginDrawingIfNeeded(at: activeTouch.location(in: view))
    onEnd?(activeTouch.location(in: view))
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    cancelStroke()
  }

  private func shouldBeginDrawing(at point: CGPoint) -> Bool {
    guard activeTouchType != .pencil, let initialPoint else { return true }
    return initialPoint.distance(to: point) >= directTouchDrawingThreshold
  }

  private func beginDrawingIfNeeded(at point: CGPoint) {
    guard didBeginDrawing == false else { return }
    didBeginDrawing = true
    state = .began
    onBegin?(initialPoint ?? point)
  }

  private func cancelStroke() {
    guard didBeginDrawing else {
      state = .failed
      return
    }
    onCancel?()
    state = .cancelled
  }
}
