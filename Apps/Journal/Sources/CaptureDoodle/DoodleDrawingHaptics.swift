import CoreGraphics
import CoreHaptics
import Foundation
import QuartzCore

/// Startup and lifecycle hooks for the haptics used by the doodle canvas.
public enum DoodleHaptics {

  /// Warms the Core Haptics engine used for drawing feedback.
  ///
  /// Call this once after app launch, or before presenting the doodle canvas, so
  /// the first stroke does not pay Core Haptics' initial engine setup cost.
  @MainActor
  public static func prepareForDrawing() {
    DoodleDrawingHaptics.prepareSharedEngine()
  }
}

/// Drives the tactile feedback used while a doodle stroke is being drawn.
///
/// `DoodleDrawingHaptics` punctuates the touch sequence with a light tap at
/// touch-down and lift, while a separate looping Core Haptics continuous player
/// supplies the in-stroke texture once drawing begins. The continuous player
/// receives lightweight dynamic parameter updates from finger speed and stops
/// immediately when the stroke ends or is cancelled. Unsupported devices,
/// including Simulator, silently no-op so the drawing surface stays usable
/// everywhere.
@MainActor
final class DoodleDrawingHaptics {

  private enum Constant {
    static let updateInterval: TimeInterval = 1.0 / 30.0
    static let loopDuration: TimeInterval = 1.0
    static let eventIntensity: Float = 0.46
    static let eventSharpness: Float = 0.58
    static let intensityControlBase: Float = 0.18
    static let intensityControlRange: Float = 0.22
    static let sharpnessControlBase: Float = -0.02
    static let sharpnessControlRange: Float = 0.12
  }

  /// The small tactile marks that bracket a stroke without becoming the texture
  /// users feel while actively drawing.
  private enum BoundaryTap {
    case start
    case end

    var intensity: Float {
      switch self {
      case .start: 0.34
      case .end: 0.28
      }
    }

    var sharpness: Float {
      switch self {
      case .start: 0.72
      case .end: 0.62
      }
    }
  }

  private static var sharedEngine: CHHapticEngine?

  private var texturePlayer: (any CHHapticAdvancedPatternPlayer)?
  private var tapPlayer: (any CHHapticPatternPlayer)?
  private var hasActiveTouch = false
  private var isPlaying = false
  private var lastUpdateTimestamp: TimeInterval = 0

  static func prepareSharedEngine() {
    guard isSupported else { return }

    do {
      _ = try runningSharedEngine()
    } catch {
      sharedEngine = nil
    }
  }

  func touchDown() {
    guard Self.isSupported else { return }

    do {
      hasActiveTouch = true
      playBoundaryTap(.start, engine: try runningEngine())
    } catch {
      hasActiveTouch = false
      tapPlayer = nil
    }
  }

  func begin() {
    guard Self.isSupported else { return }

    stopTexturePlayer()

    do {
      let engine = try runningEngine()
      let texturePlayer = try engine.makeAdvancedPlayer(with: try makeTexturePattern())
      texturePlayer.loopEnabled = true
      texturePlayer.loopEnd = Constant.loopDuration
      try texturePlayer.start(atTime: CHHapticTimeImmediate)
      self.texturePlayer = texturePlayer
      isPlaying = true
      lastUpdateTimestamp = 0
      update(speed: 0, timestamp: CACurrentMediaTime())
    } catch {
      stopTexturePlayer()
    }
  }

  func update(speed: CGFloat, timestamp: TimeInterval) {
    guard isPlaying, let texturePlayer else { return }
    guard timestamp - lastUpdateTimestamp >= Constant.updateInterval else { return }

    let normalizedSpeed = Float(smoothstep(edge0: 40, edge1: 900, value: speed))
    let intensity = Constant.intensityControlBase + normalizedSpeed * Constant.intensityControlRange
    let sharpness = Constant.sharpnessControlBase + normalizedSpeed * Constant.sharpnessControlRange

    let parameters = [
      CHHapticDynamicParameter(
        parameterID: .hapticIntensityControl,
        value: intensity,
        relativeTime: 0
      ),
      CHHapticDynamicParameter(
        parameterID: .hapticSharpnessControl,
        value: sharpness,
        relativeTime: 0
      ),
    ]

    do {
      try texturePlayer.sendParameters(parameters, atTime: CHHapticTimeImmediate)
      lastUpdateTimestamp = timestamp
    } catch {
      stopTexturePlayer()
    }
  }

  func end() {
    guard Self.isSupported else { return }

    let shouldPlayEndTap = hasActiveTouch
    stopTexturePlayer()
    hasActiveTouch = false

    guard shouldPlayEndTap else { return }
    do {
      playBoundaryTap(.end, engine: try runningEngine())
    } catch {
      tapPlayer = nil
    }
  }

  func cancel() {
    stopTexturePlayer()
    hasActiveTouch = false
  }

  private static var isSupported: Bool {
    CHHapticEngine.capabilitiesForHardware().supportsHaptics
  }

  private func runningEngine() throws -> CHHapticEngine {
    try Self.runningSharedEngine()
  }

  private static func runningSharedEngine() throws -> CHHapticEngine {
    if let engine = sharedEngine {
      try engine.start()
      return engine
    }

    let engine = try CHHapticEngine()
    engine.isAutoShutdownEnabled = true
    sharedEngine = engine
    try engine.start()
    return engine
  }

  private func playBoundaryTap(_ tap: BoundaryTap, engine: CHHapticEngine) {
    do {
      let player = try engine.makePlayer(with: try makeBoundaryTapPattern(tap))
      try player.start(atTime: CHHapticTimeImmediate)
      tapPlayer = player
    } catch {
      tapPlayer = nil
    }
  }

  private func makeBoundaryTapPattern(_ tap: BoundaryTap) throws -> CHHapticPattern {
    let event = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.intensity),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.sharpness),
      ],
      relativeTime: 0
    )

    return try CHHapticPattern(events: [event], parameters: [])
  }

  private func makeTexturePattern() throws -> CHHapticPattern {
    let event = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: Constant.eventIntensity),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: Constant.eventSharpness),
        CHHapticEventParameter(parameterID: .attackTime, value: 0),
        CHHapticEventParameter(parameterID: .releaseTime, value: 0.04),
      ],
      relativeTime: 0,
      duration: Constant.loopDuration
    )

    return try CHHapticPattern(events: [event], parameters: [])
  }

  private func stopTexturePlayer() {
    try? texturePlayer?.stop(atTime: CHHapticTimeImmediate)
    texturePlayer = nil
    isPlaying = false
    lastUpdateTimestamp = 0
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}
