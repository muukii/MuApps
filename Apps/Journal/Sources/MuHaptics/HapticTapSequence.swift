import Foundation

/// A hand-authored sequence of transient haptic taps.
///
/// This is the haptic counterpart to a doodle's timestamped stroke timeline:
/// users create it by tapping in rhythm, and playback lowers the captured tap
/// times into a Core Haptics pattern.
public struct HapticTapSequence: Codable, Equatable, Identifiable, Sendable {

  public var id: UUID
  public var name: String
  public var taps: [Tap]

  public init(
    id: UUID = UUID(),
    name: String = "Untitled Sequence",
    taps: [Tap] = []
  ) {
    self.id = id
    self.name = name
    self.taps = taps
  }

  /// The final tap time in seconds. A single tap has a duration of zero but is
  /// still playable.
  public var duration: TimeInterval {
    taps.map(\.time).max() ?? 0
  }

  /// Whether this sequence has no captured taps.
  public var isEmpty: Bool {
    taps.isEmpty
  }

  /// Converts the captured taps into the general haptic pattern model.
  public var pattern: HapticPattern {
    HapticPattern(
      name: name,
      events: taps
        .sorted { $0.time < $1.time }
        .map { tap in
          HapticPattern.Event(
            kind: .transient,
            time: tap.time,
            intensity: tap.intensity,
            sharpness: tap.sharpness
          )
        }
    )
  }

  /// Adds a tap to the timeline and returns the inserted value so callers can
  /// preview exactly what was captured.
  @discardableResult
  public mutating func appendTap(
    at time: TimeInterval,
    intensity: Float = 0.85,
    sharpness: Float = 0.72
  ) -> Tap {
    let tap = Tap(time: max(0, time), intensity: intensity, sharpness: sharpness)
    taps.append(tap)
    return tap
  }

  /// Removes the newest authored tap. Ordering is by insertion, not by timestamp,
  /// matching how a user thinks about undo while tapping out a rhythm.
  public mutating func removeLastTap() {
    guard taps.isEmpty == false else { return }
    taps.removeLast()
  }
}

extension HapticTapSequence {

  /// One transient haptic tap on a sequence timeline.
  ///
  /// `time` is relative to the sequence's beginning. `intensity` controls
  /// strength, while `sharpness` controls whether the tap feels soft or crisp.
  public struct Tap: Codable, Equatable, Identifiable, Sendable {

    public var id: UUID
    public var time: TimeInterval
    public var intensity: Float
    public var sharpness: Float

    public init(
      id: UUID = UUID(),
      time: TimeInterval,
      intensity: Float = 0.85,
      sharpness: Float = 0.72
    ) {
      self.id = id
      self.time = max(0, time)
      self.intensity = intensity
      self.sharpness = sharpness
    }
  }
}

// MARK: - Code generation

extension HapticTapSequence {

  /// Emits Swift source that reconstructs this tap sequence.
  public var swiftSourceCode: String {
    let tapLines = taps
      .sorted { $0.time < $1.time }
      .map { "    \($0.swiftSourceCode)," }
      .joined(separator: "\n")

    return """
      HapticTapSequence(
        name: \"\(name)\",
        taps: [
      \(tapLines)
        ]
      )
      """
  }
}

extension HapticTapSequence.Tap {

  fileprivate var swiftSourceCode: String {
    ".init(time: \(format(time)), intensity: \(format(intensity)), sharpness: \(format(sharpness)))"
  }

  private func format(_ value: some BinaryFloatingPoint) -> String {
    String(format: "%g", Double(value))
  }
}
