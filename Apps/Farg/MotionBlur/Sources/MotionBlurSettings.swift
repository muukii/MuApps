//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import VideoToolbox

/// User-authored parameters for Optical Flow motion blur.
///
/// `strength` intentionally mirrors VideoToolbox's documented 1...100 range.
/// It is not labeled as a shutter angle because Apple does not define a
/// physical shutter-angle conversion for `VTMotionBlurParameters`.
public struct MotionBlurSettings: Equatable, Sendable {

  /// The range accepted by `VTMotionBlurParameters`.
  public static let strengthRange = 1...100

  /// A recipe that bypasses all temporal processing.
  public static let disabled = MotionBlurSettings(isEnabled: false)

  /// Whether the temporal renderer participates in preview and export.
  public var isEnabled: Bool

  /// Optical Flow motion-blur strength in VideoToolbox units.
  public var strength: Int {
    didSet {
      strength = Self.clampedStrength(strength)
    }
  }

  /// Creates motion-blur settings, normalizing strength to VideoToolbox's
  /// supported range.
  public init(
    isEnabled: Bool = false,
    strength: Int = 50
  ) {
    self.isEnabled = isEnabled
    self.strength = Self.clampedStrength(strength)
  }

  private static func clampedStrength(_ strength: Int) -> Int {
    min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
  }
}

/// A thread-safe live strength value shared by Preview composition instructions.
///
/// VideoToolbox reads strength synchronously for each frame. Keeping this one
/// value behind a lock lets the editor update Strength without replacing its
/// `AVVideoComposition`, custom compositor, or player item.
public final class MotionBlurStrengthSource: @unchecked Sendable {

  private let lock = NSLock()
  private var storedStrength: Int
  private var processorSessionResetHandlers: [UUID: @Sendable () -> Void] = [:]

  /// Creates a source whose value is normalized to VideoToolbox's 1...100 range.
  public init(strength: Int) {
    self.storedStrength = MotionBlurSettings(strength: strength).strength
  }

  /// Returns one stable value for the duration of a compositor request.
  public func snapshot() -> Int {
    lock.lock()
    defer {
      lock.unlock()
    }
    return storedStrength
  }

  /// Changes the value consumed by subsequent compositor requests.
  public func update(strength: Int) {
    let normalizedStrength = MotionBlurSettings(strength: strength).strength
    lock.lock()
    storedStrength = normalizedStrength
    lock.unlock()
  }

  /// Requests immediate release of processor sessions reading this source.
  ///
  /// A paused player may not request a bypass frame after Motion Blur is
  /// disabled. Explicit invalidation prevents the previous VideoToolbox session
  /// and its IOSurfaces from waiting for playback to resume before releasing.
  public func requestProcessorSessionReset() {
    lock.lock()
    let handlers = Array(processorSessionResetHandlers.values)
    lock.unlock()
    for handler in handlers {
      handler()
    }
  }

  func registerProcessorSessionResetHandler(
    id: UUID,
    _ handler: @escaping @Sendable () -> Void
  ) {
    lock.lock()
    processorSessionResetHandlers[id] = handler
    lock.unlock()
  }

  func unregisterProcessorSessionResetHandler(id: UUID) {
    lock.lock()
    processorSessionResetHandlers[id] = nil
    lock.unlock()
  }
}

/// Runtime support for Färg's Optical Flow motion-blur backend.
public enum MotionBlurAvailability {

  /// Whether the current device exposes Apple's motion-blur frame processor.
  public static var isSupported: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      VTMotionBlurConfiguration.isSupported
    #endif
  }
}

/// Internal quality policy used when configuring VideoToolbox.
public enum MotionBlurQuality: Equatable, Sendable {
  /// Prioritizes interactive preview and ordinary export throughput.
  case normal

  /// Requests VideoToolbox's higher-quality processing mode.
  case quality
}
