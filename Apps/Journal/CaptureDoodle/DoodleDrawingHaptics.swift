import CoreGraphics
import CoreHaptics
import Foundation
import QuartzCore

/// Drives the tactile texture used while a doodle stroke is being drawn.
///
/// `DoodleDrawingHaptics` owns a single looping Core Haptics continuous player.
/// The player starts when drawing begins, receives lightweight dynamic
/// parameter updates from finger speed, and stops immediately when the stroke
/// ends or is cancelled. Unsupported devices, including Simulator, silently
/// no-op so the drawing surface stays usable everywhere.
@MainActor
final class DoodleDrawingHaptics {

  private enum Constant {
    static let updateInterval: TimeInterval = 1.0 / 30.0
    static let loopDuration: TimeInterval = 1.0
    static let eventIntensity: Float = 1.0
    static let eventSharpness: Float = 0.88
    static let intensityControlBase: Float = 0.16
    static let intensityControlRange: Float = 0.28
    static let sharpnessControlBase: Float = -0.08
    static let sharpnessControlRange: Float = 0.16
  }

  private var engine: CHHapticEngine?
  private var player: (any CHHapticAdvancedPatternPlayer)?
  private var isPlaying = false
  private var lastUpdateTimestamp: TimeInterval = 0

  func begin() {
    guard Self.isSupported else { return }

    stopPlayer()

    do {
      let engine = try runningEngine()
      let player = try engine.makeAdvancedPlayer(with: try makeTexturePattern())
      player.loopEnabled = true
      player.loopEnd = Constant.loopDuration
      try player.start(atTime: CHHapticTimeImmediate)
      self.player = player
      isPlaying = true
      lastUpdateTimestamp = 0
      update(speed: 0, timestamp: CACurrentMediaTime())
    } catch {
      stopPlayer()
    }
  }

  func update(speed: CGFloat, timestamp: TimeInterval) {
    guard isPlaying, let player else { return }
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
      try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
      lastUpdateTimestamp = timestamp
    } catch {
      stopPlayer()
    }
  }

  func end() {
    stopPlayer()
  }

  private static var isSupported: Bool {
    CHHapticEngine.capabilitiesForHardware().supportsHaptics
  }

  private func runningEngine() throws -> CHHapticEngine {
    if let engine {
      try engine.start()
      return engine
    }

    let engine = try CHHapticEngine()
    engine.isAutoShutdownEnabled = true
    self.engine = engine
    try engine.start()
    return engine
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

  private func stopPlayer() {
    try? player?.stop(atTime: CHHapticTimeImmediate)
    player = nil
    isPlaying = false
    lastUpdateTimestamp = 0
  }

  private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
    let progress = min(max((value - edge0) / max(edge1 - edge0, 1), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}
