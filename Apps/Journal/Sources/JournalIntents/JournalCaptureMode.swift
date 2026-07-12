import AppIntents
import Foundation

/// A Journal authoring surface that can be opened from a system entry point.
///
/// The cases intentionally match capture flows that can start after Journal has
/// opened. Locked Camera Capture is a separate extension architecture and is
/// not represented here.
public enum JournalCaptureMode: String, AppEnum, CaseIterable, Sendable {
  /// Opens the focused text composer.
  case text

  /// Opens Journal's camera capture sheet.
  case photo

  /// Opens the voice recorder.
  case voice

  /// Opens the doodle canvas.
  case doodle

  /// Opens Apple's Journaling Suggestions picker.
  case suggestion

  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture Mode"

  public static let caseDisplayRepresentations: [JournalCaptureMode: DisplayRepresentation] = [
    // App Intents metadata extraction requires literal representations here.
    // `displayTitle` and `systemImageName` remain the runtime UI equivalents.
    .text: "Text",
    .photo: "Photo",
    .voice: "Voice",
    .doodle: "Doodle",
    .suggestion: "Suggestion",
  ]

  /// Localized title shared by App Intents metadata and WidgetKit controls.
  public var displayTitle: LocalizedStringResource {
    switch self {
    case .text:
      "Text"
    case .photo:
      "Photo"
    case .voice:
      "Voice"
    case .doodle:
      "Doodle"
    case .suggestion:
      "Suggestion"
    }
  }

  /// SF Symbol name used by system capture entry points.
  public var systemImageName: String {
    switch self {
    case .text:
      "text.cursor"
    case .photo:
      "camera"
    case .voice:
      "waveform"
    case .doodle:
      "scribble.variable"
    case .suggestion:
      "sparkles"
    }
  }
}
