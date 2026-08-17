import Foundation

/// A compact, versioned history of measured audio input levels.
///
/// The recorder samples its meter at `sampleInterval` and quantizes each
/// normalized `0...1` level to one byte. Encoding this value with `Codable`
/// produces the JSON payload persisted beside the audio resource; `levels`
/// is represented as Base64 by `JSONEncoder`.
public struct AudioWaveform: Codable, Equatable, Sendable {

  /// The payload version written by this build.
  public static let currentFormatVersion = 1

  /// The nominal time, in seconds, between consecutive measurements.
  public let sampleInterval: TimeInterval

  /// Quantized normalized levels, ordered from the start of the recording.
  public let levels: Data

  /// Payload version used to reject formats this build cannot interpret.
  public let formatVersion: Int

  /// Creates a waveform by clamping and quantizing normalized meter levels.
  public init(
    normalizedLevels: [Float],
    sampleInterval: TimeInterval
  ) {
    self.init(
      sampleInterval: sampleInterval,
      levels: Data(normalizedLevels.map(Self.quantizedLevel))
    )
  }

  /// Decodes and validates a persisted waveform JSON payload.
  ///
  /// Unsupported versions and structurally invalid values return `nil`, which
  /// lets callers render a legacy fallback without making the audio unusable.
  public static func decode(from data: Data) -> AudioWaveform? {
    guard let waveform = try? JSONDecoder().decode(AudioWaveform.self, from: data),
      waveform.formatVersion == currentFormatVersion,
      waveform.sampleInterval.isFinite,
      waveform.sampleInterval > 0,
      waveform.levels.isEmpty == false
    else {
      return nil
    }

    return waveform
  }

  /// Encodes this waveform as the versioned JSON payload used by persistence.
  public func encodedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  /// Normalized `0...1` levels for consumers that need floating-point values.
  public var normalizedLevels: [Float] {
    levels.map { Float($0) / Float(UInt8.max) }
  }

  init(
    sampleInterval: TimeInterval,
    levels: Data,
    formatVersion: Int = currentFormatVersion
  ) {
    self.sampleInterval = sampleInterval
    self.levels = levels
    self.formatVersion = formatVersion
  }

  static func quantizedLevel(_ level: Float) -> UInt8 {
    let clampedLevel = min(max(level, 0), 1)
    return UInt8((clampedLevel * Float(UInt8.max)).rounded())
  }
}
