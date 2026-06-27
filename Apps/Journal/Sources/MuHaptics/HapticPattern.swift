import CoreHaptics
import Foundation

/// An editable, value-type description of a haptic pattern: a timeline of
/// events, each a tap (`transient`) or a sustained buzz (`continuous`). This is
/// the model the editor mutates; `makeCHHapticPattern()` lowers it into the
/// Core Haptics type at playback time.
///
/// Kept deliberately small — transient + continuous events with intensity and
/// sharpness over a timeline already cover the vast majority of expressive
/// haptics. For anything beyond that, feed a raw AHAP to `HapticEngine.play(ahap:)`.
public struct HapticPattern: Equatable, Sendable, Identifiable {

  public var id: UUID
  public var name: String
  public var events: [Event]

  public init(
    id: UUID = UUID(),
    name: String = "Untitled",
    events: [Event] = []
  ) {
    self.id = id
    self.name = name
    self.events = events
  }

  /// Total timeline length, used by the editor to lay out the track.
  public var duration: TimeInterval {
    events.map(\.endTime).max() ?? 0
  }

  /// Lowers the model into a `CHHapticPattern` for the engine to play.
  public func makeCHHapticPattern() throws -> CHHapticPattern {
    try CHHapticPattern(events: events.map { $0.makeCHHapticEvent() }, parameters: [])
  }
}

extension HapticPattern {

  /// A single point on the haptic timeline.
  ///
  /// `intensity` is how strong (0 = none, 1 = full) and `sharpness` is the
  /// texture (0 = round/dull thud, 1 = crisp/precise click). `duration` only
  /// applies to `continuous` events; it is ignored for `transient` taps.
  public struct Event: Identifiable, Equatable, Sendable {

    public enum Kind: Equatable, Sendable, CaseIterable {
      /// A momentary tap — duration has no effect.
      case transient
      /// A sustained vibration spanning `duration`.
      case continuous
    }

    public let id: UUID
    public var kind: Kind
    /// Start time relative to the pattern's beginning, in seconds.
    public var time: TimeInterval
    /// Length in seconds. Only meaningful for `continuous`.
    public var duration: TimeInterval
    public var intensity: Float
    public var sharpness: Float

    public init(
      id: UUID = UUID(),
      kind: Kind,
      time: TimeInterval,
      duration: TimeInterval = 0.25,
      intensity: Float = 1.0,
      sharpness: Float = 0.5
    ) {
      self.id = id
      self.kind = kind
      self.time = time
      self.duration = duration
      self.intensity = intensity
      self.sharpness = sharpness
    }

    /// Where this event ends on the timeline. Transient events are treated as a
    /// short fixed slice so they remain visible/selectable in the editor track.
    public var endTime: TimeInterval {
      switch kind {
      case .transient: time + 0.05
      case .continuous: time + duration
      }
    }

    func makeCHHapticEvent() -> CHHapticEvent {
      let parameters = [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
      ]

      switch kind {
      case .transient:
        return CHHapticEvent(
          eventType: .hapticTransient,
          parameters: parameters,
          relativeTime: time
        )
      case .continuous:
        return CHHapticEvent(
          eventType: .hapticContinuous,
          parameters: parameters,
          relativeTime: time,
          duration: duration
        )
      }
    }
  }
}

// MARK: - Code generation

extension HapticPattern {

  /// Emits the Swift literal that reconstructs this pattern, so a pattern dialed
  /// in inside the editor can be copied straight into source. This is the bridge
  /// that makes the editor actually *useful* — design here, paste into the app.
  public var swiftSourceCode: String {
    let eventLines = events.map { "    \($0.swiftSourceCode)," }.joined(separator: "\n")
    return """
      HapticPattern(
        name: \"\(name)\",
        events: [
      \(eventLines)
        ]
      )
      """
  }
}

extension HapticPattern.Event {

  /// A `.init(...)` literal for this event, omitting arguments that match their
  /// defaults (duration only appears for continuous events).
  fileprivate var swiftSourceCode: String {
    let kindLiteral: String = {
      switch kind {
      case .transient: ".transient"
      case .continuous: ".continuous"
      }
    }()

    var arguments = ["kind: \(kindLiteral)", "time: \(format(time))"]
    switch kind {
    case .transient:
      break
    case .continuous:
      arguments.append("duration: \(format(duration))")
    }
    arguments.append("intensity: \(format(intensity))")
    arguments.append("sharpness: \(format(sharpness))")

    return ".init(\(arguments.joined(separator: ", ")))"
  }

  private func format(_ value: some BinaryFloatingPoint) -> String {
    String(format: "%g", Double(value))
  }
}

// MARK: - Presets

extension HapticPattern {

  /// Starter patterns for the gallery/editor so there's always something to play.
  public static let presets: [HapticPattern] = [
    .singleTap,
    .doubleTap,
    .heartbeat,
    .rampUp,
  ]

  public static var singleTap: HapticPattern {
    .init(
      name: "Single Tap",
      events: [.init(kind: .transient, time: 0, intensity: 1, sharpness: 0.5)]
    )
  }

  public static var doubleTap: HapticPattern {
    .init(
      name: "Double Tap",
      events: [
        .init(kind: .transient, time: 0, intensity: 1, sharpness: 0.7),
        .init(kind: .transient, time: 0.12, intensity: 1, sharpness: 0.7),
      ]
    )
  }

  public static var heartbeat: HapticPattern {
    .init(
      name: "Heartbeat",
      events: [
        .init(kind: .transient, time: 0, intensity: 1.0, sharpness: 0.3),
        .init(kind: .transient, time: 0.18, intensity: 0.6, sharpness: 0.2),
      ]
    )
  }

  public static var rampUp: HapticPattern {
    .init(
      name: "Ramp Up",
      events: [
        .init(kind: .continuous, time: 0, duration: 0.6, intensity: 0.4, sharpness: 0.1),
        .init(kind: .transient, time: 0.6, intensity: 1.0, sharpness: 0.9),
      ]
    )
  }
}
