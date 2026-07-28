//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// User-authored parameters for the film-grain overlay.
///
/// Grain is a purely spatial, single-frame Core Image effect. Unlike Optical
/// Flow motion blur it has no device-support gate, no temporal neighbors, and
/// remains available in Simulator.
nonisolated struct GrainSettings: Equatable, Sendable {

  /// The user-facing range shared by `intensity` and `size`.
  static let valueRange = 1...100

  /// A recipe with no grain overlay.
  static let disabled = GrainSettings(isEnabled: false)

  /// Whether the grain overlay participates in preview and export.
  var isEnabled: Bool

  /// The visibility of the grain texture.
  var intensity: Int {
    didSet {
      intensity = Self.clamped(intensity)
    }
  }

  /// The relative grain-particle size.
  ///
  /// The rendered pitch resolves against the output height, so the
  /// viewport-fitted preview and the source-resolution export show the same
  /// texture scale.
  var size: Int {
    didSet {
      size = Self.clamped(size)
    }
  }

  /// Creates grain settings, normalizing both values to the supported range.
  init(
    isEnabled: Bool = false,
    intensity: Int = 50,
    size: Int = 50
  ) {
    self.isEnabled = isEnabled
    self.intensity = Self.clamped(intensity)
    self.size = Self.clamped(size)
  }

  private static func clamped(_ value: Int) -> Int {
    min(max(value, valueRange.lowerBound), valueRange.upperBound)
  }
}

/// A thread-safe live parameter pair shared by Preview composition instructions.
///
/// The compositor's post-processor reads grain parameters synchronously for
/// each frame. Keeping them behind a lock lets the editor's sliders update
/// without replacing the `AVVideoComposition`, custom compositor, or player
/// item — the same contract `MotionBlurStrengthSource` provides for Strength.
nonisolated final class GrainParameterSource: @unchecked Sendable {

  struct Snapshot: Equatable, Sendable {
    let intensity: Int
    let size: Int
  }

  private let lock = NSLock()
  private var storedIntensity: Int
  private var storedSize: Int

  /// Creates a source whose values are normalized by `GrainSettings`.
  init(settings: GrainSettings) {
    self.storedIntensity = settings.intensity
    self.storedSize = settings.size
  }

  /// Returns one stable pair for the duration of a compositor request.
  func snapshot() -> Snapshot {
    lock.lock()
    defer {
      lock.unlock()
    }
    return Snapshot(intensity: storedIntensity, size: storedSize)
  }

  /// Changes the values consumed by subsequent compositor requests.
  func update(settings: GrainSettings) {
    lock.lock()
    storedIntensity = settings.intensity
    storedSize = settings.size
    lock.unlock()
  }
}
