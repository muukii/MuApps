import MetalKit
import UIKit

/// MTKView that wires the drawing gesture → stroke smoother → stamp decimation →
/// Metal ink renderer. Idle by default (`isPaused`/`enableSetNeedsDisplay`); a
/// `CADisplayLink` paces redraws only while a stroke is in flight, with immediate
/// flushes on begin/end for low latency.
@MainActor
final class DoodleMetalView: MTKView {

  var brush = InkBrush()
  var smoothing = InkSmoothing() {
    didSet { smoother.configure(smoothing) }
  }

  private let renderer: InkMetalRenderer
  private var smoother = StrokeSmoother()
  private var lastStampPoint: CGPoint?
  private var liveDisplayLink: CADisplayLink?

  /// Builds a canvas, or `nil` if Metal is unavailable / shaders fail to compile.
  static func make() -> DoodleMetalView? {
    guard
      let device = MTLCreateSystemDefaultDevice(),
      let renderer = InkMetalRenderer(device: device)
    else {
      return nil
    }
    return DoodleMetalView(renderer: renderer, device: device)
  }

  private init(renderer: InkMetalRenderer, device: MTLDevice) {
    self.renderer = renderer
    super.init(frame: .zero, device: device)

    isOpaque = false
    backgroundColor = .clear
    layer.isOpaque = false
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    framebufferOnly = true
    enableSetNeedsDisplay = true
    isPaused = true
    autoResizeDrawable = true
    isMultipleTouchEnabled = true
    preferredFramesPerSecond = 120
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.maximumDrawableCount = 3
    }
    delegate = self

    let recognizer = DrawingGestureRecognizer(target: nil, action: nil)
    recognizer.onBegin = { [weak self] point in self?.beginStroke(at: point) }
    recognizer.onMove = { [weak self] points in self?.appendStroke(points) }
    recognizer.onEnd = { [weak self] point in self?.endStroke(at: point) }
    recognizer.onCancel = { [weak self] in self?.cancelStroke() }
    addGestureRecognizer(recognizer)
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Editing API (driven by SwiftUI)

  func undo() {
    renderer.undo()
    setNeedsDisplay()
  }

  func clearCanvas() {
    renderer.clear()
    setNeedsDisplay()
  }

  func exportImage() -> UIImage? {
    renderer.exportImage()
  }

  // MARK: - Stroke handling

  /// Half the stamp spacing, floored — the resolution the smoother resamples to.
  private var sampleDistance: CGFloat {
    max(CGFloat(brush.size * brush.spacing) * 0.5, 2)
  }

  private func beginStroke(at point: CGPoint) {
    smoother.configure(smoothing)
    smoother.begin(at: point)
    lastStampPoint = nil
    renderer.beginStroke(brush: brush)
    renderer.appendStamps(stampPoints(to: point))
    setNeedsDisplay()
    startLiveDisplayLink()
  }

  private func appendStroke(_ points: [CGPoint]) {
    let smoothed = smoother.append(points, sampleDistance: sampleDistance)
    renderer.appendStamps(stamps(from: smoothed))
  }

  private func endStroke(at point: CGPoint) {
    let smoothed = smoother.finish(at: point, sampleDistance: sampleDistance)
    renderer.appendStamps(stamps(from: smoothed))
    renderer.endStroke()
    lastStampPoint = nil
    stopLiveDisplayLink()
    setNeedsDisplay()
  }

  private func cancelStroke() {
    renderer.cancelStroke()
    lastStampPoint = nil
    stopLiveDisplayLink()
    setNeedsDisplay()
  }

  private func stamps(from smoothed: [CGPoint]) -> [CGPoint] {
    var result: [CGPoint] = []
    for point in smoothed {
      result += stampPoints(to: point)
    }
    return result
  }

  /// Fixed arc-length stamp decimation, ported from Brightroom's `stampPoints`.
  private func stampPoints(to point: CGPoint) -> [CGPoint] {
    guard let last = lastStampPoint else {
      lastStampPoint = point
      return [point]
    }
    let distance = hypot(point.x - last.x, point.y - last.y)
    let spacing = max(CGFloat(brush.size * brush.spacing), 1)
    guard distance >= spacing else { return [] }
    let count = Int(distance / spacing)
    guard count > 0 else { return [] }

    var result: [CGPoint] = []
    var newest = last
    for index in 1...count {
      let progress = CGFloat(index) * spacing / distance
      let stamp = CGPoint(
        x: last.x + (point.x - last.x) * progress,
        y: last.y + (point.y - last.y) * progress
      )
      result.append(stamp)
      newest = stamp
    }
    lastStampPoint = newest
    return result
  }

  // MARK: - Display link

  private func startLiveDisplayLink() {
    guard liveDisplayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(liveTick))
    link.add(to: .main, forMode: .common)
    liveDisplayLink = link
  }

  private func stopLiveDisplayLink() {
    liveDisplayLink?.invalidate()
    liveDisplayLink = nil
  }

  @objc private func liveTick() {
    setNeedsDisplay()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      // Break the display link's strong retain of self when leaving the hierarchy.
      stopLiveDisplayLink()
    }
  }
}

// MARK: - MTKViewDelegate

extension DoodleMetalView: MTKViewDelegate {
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    let scale = bounds.width > 0 ? size.width / bounds.width : contentScaleFactor
    renderer.resize(pixelSize: size, scale: scale)
  }

  func draw(in view: MTKView) {
    renderer.render(in: view)
  }
}
