import CoreHaptics
import Foundation

/// Plays arbitrary haptic patterns through Core Haptics.
///
/// Wraps a single `CHHapticEngine` and hides its lifecycle quirks: the engine
/// auto-shuts-down when idle (to save power) and is stopped by the system on
/// interruptions (incoming call, backgrounding). Both cases leave a dead engine
/// that throws on the next `makePlayer`. We recover by lazily (re)starting the
/// engine on every `play`, and by reattaching the reset/stopped handlers each
/// time we create it — so callers never have to think about engine state.
///
/// Not `Sendable`: `CHHapticEngine` is main-actor friendly here and the editor
/// drives it from the main actor only.
@MainActor
public final class HapticEngine {

  public enum Error: Swift.Error {
    /// The device has no haptic hardware (Simulator, iPad, older/Plus iPhones).
    case hapticsUnavailable
    case engineFailure(Swift.Error)
  }

  /// Whether this device can play Core Haptics at all. Read this before showing
  /// haptic UI — on unsupported hardware every `play` throws `.hapticsUnavailable`.
  public static var isSupported: Bool {
    CHHapticEngine.capabilitiesForHardware().supportsHaptics
  }

  private var engine: CHHapticEngine?

  public init() {}

  /// Plays a pattern once, starting the engine if needed. Throws rather than
  /// silently no-op'ing so the editor can surface failures.
  public func play(_ pattern: HapticPattern) throws {
    guard Self.isSupported else { throw Error.hapticsUnavailable }

    do {
      let engine = try runningEngine()
      let player = try engine.makePlayer(with: try pattern.makeCHHapticPattern())
      try player.start(atTime: CHHapticTimeImmediate)
    } catch let error as Error {
      throw error
    } catch {
      throw Error.engineFailure(error)
    }
  }

  /// Plays a raw AHAP (Apple Haptic Audio Pattern) dictionary. This is the
  /// escape hatch for patterns authored outside the editor — any valid AHAP can
  /// be fed in verbatim, which is what makes "arbitrary" haptics truly arbitrary.
  public func play(ahap dictionary: [CHHapticPattern.Key: Any]) throws {
    guard Self.isSupported else { throw Error.hapticsUnavailable }

    do {
      let engine = try runningEngine()
      let player = try engine.makePlayer(with: try CHHapticPattern(dictionary: dictionary))
      try player.start(atTime: CHHapticTimeImmediate)
    } catch let error as Error {
      throw error
    } catch {
      throw Error.engineFailure(error)
    }
  }

  /// Returns a started engine, creating it on first use and restarting it if the
  /// system stopped it. `start()` is idempotent on an already-running engine.
  private func runningEngine() throws -> CHHapticEngine {
    if let engine {
      try engine.start()
      return engine
    }

    let engine = try CHHapticEngine()

    // Auto-shutdown saves power but means we must be ready to restart — which
    // `runningEngine()` already does on the next call.
    engine.isAutoShutdownEnabled = true

    // The engine can reset after a media-services crash; recreate the player by
    // simply restarting. We hold no long-lived players, so restart is enough.
    engine.resetHandler = { [weak engine] in
      try? engine?.start()
    }

    self.engine = engine
    try engine.start()
    return engine
  }
}
