import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import Foundation
import JournalVault

/// Feature-local source values needed to create a share snapshot.
///
/// `SavedListView` builds this from its live vault entry projection so the
/// sharing layer does not need access to private saved-list types or live
/// SwiftData models.
struct EntryShareSource: Sendable, Equatable {
  let id: UUID
  let kind: JournalVault.Card.Kind
  let body: String
  let completedAt: Date?
  let attachment: EntryShareAttachmentSource?
}

/// File-backed attachment values used by the share/export boundary.
struct EntryShareAttachmentSource: Sendable, Equatable {
  let kind: JournalVault.Attachment.Kind
  let fileURL: URL
  let thumbnail: Data?
  let contentType: String?
  let byteSize: Int?
  /// Measured length of a time-based resource, in seconds.
  let duration: TimeInterval?
}

/// A detached, share-ready copy of one saved vault entry.
///
/// Sharing should not hold a live SwiftData model while rendering images or
/// videos. This snapshot reads the saved entry once, resolves its primary
/// attachment, and carries only value data into the export layer.
struct EntryShareSnapshot: Identifiable, Sendable, Equatable {

  /// Stable entry identity, reused for temporary export file names.
  var id: UUID

  /// Authored-content value reused by Home Cell and export rendering.
  var content: EntryContent

  /// Creates a detached snapshot from already-resolved content.
  ///
  /// This initializer keeps previews and renderer tests independent from the
  /// vault's file-backed attachment resolution path.
  init(
    id: UUID,
    content: EntryContent
  ) {
    self.id = id
    self.content = content
  }

  /// Builds a snapshot from saved vault-entry values.
  ///
  /// Media files are read from the selected vault's media directory when
  /// present. Missing files degrade to mirrored thumbnails or placeholders
  /// instead of failing, because sharing should still work for partially
  /// available CloudKit rows.
  init(source: EntryShareSource) {
    let body = source.body.trimmingCharacters(in: .whitespacesAndNewlines)

    self.id = source.id
    self.content = Self.makeContent(
      kind: source.kind,
      body: body,
      completedAt: source.completedAt,
      attachment: source.attachment
    )
  }

  private static func makeContent(
    kind: JournalVault.Card.Kind,
    body: String,
    completedAt: Date?,
    attachment: EntryShareAttachmentSource?
  ) -> EntryContent {
    switch kind {
    case .text, .link:
      return .text(body)
    case .todo:
      return .todo(
        TodoContentSource(text: body, completedAt: completedAt)
      )
    case .file:
      let fileAttachment = attachment?.kind == .file ? attachment : nil
      let availableFileURL = fileURL(for: fileAttachment)
      return .file(
        FileContentSource(
          displayName: fileDisplayName(
            body: body,
            fileURL: availableFileURL ?? fileAttachment?.fileURL
          ),
          fileURL: availableFileURL,
          contentType: fileAttachment?.contentType,
          byteSize: fileAttachment?.byteSize
        )
      )
    case .suggestion:
      return .text(SuggestionShareTextFormatter.text(from: fileData(for: attachment)))
    case .photo, .livePhoto:
      return .photo(
        PhotoContentSource(
          imageData: fileData(for: attachment) ?? attachment?.thumbnail
        )
      )
    case .video:
      return .photo(PhotoContentSource(imageData: attachment?.thumbnail))
    case .audio:
      return .audio(
        AudioContentSource(
          fileURL: fileURL(for: attachment),
          duration: attachment?.duration
        )
      )
    case .doodle:
      let drawingData = fileData(for: attachment)
      let drawing = drawingData.flatMap {
        try? JSONDecoder().decode(DoodleDrawing.self, from: $0)
      }
      return .doodle(
        DoodleContentSource(
          drawing: drawing,
          thumbnailData: attachment?.thumbnail
        )
      )
    case .bauhaus:
      let documentData = fileData(for: attachment)
      let document = documentData.flatMap {
        try? JSONDecoder().decode(BauhausGridDocument.self, from: $0)
      }
      return .bauhaus(
        BauhausContentSource(
          document: document,
          thumbnailData: attachment?.thumbnail
        )
      )
    case .unknown:
      return .text(body)
    @unknown default:
      return .text(body)
    }
  }

  private static func fileData(for attachment: EntryShareAttachmentSource?) -> Data? {
    guard let url = fileURL(for: attachment) else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func fileURL(for attachment: EntryShareAttachmentSource?) -> URL? {
    guard let attachment else { return nil }
    guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
      return nil
    }
    return attachment.fileURL
  }

  private static func fileDisplayName(body: String, fileURL: URL?) -> String {
    if body.isEmpty == false {
      return body
    }

    if let fileURL, fileURL.lastPathComponent.isEmpty == false {
      return fileURL.lastPathComponent
    }

    return String(localized: "File")
  }
}

private enum SuggestionShareTextFormatter {

  static func text(from data: Data?) -> String {
    guard let data,
      let suggestion = SuggestionCardPayload.decode(from: data)
    else {
      return String(localized: "Journaling Suggestion")
    }

    var lines: [String] = []
    let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
    lines.append(title.isEmpty ? String(localized: "Journaling Suggestion") : title)

    if let dateInterval = suggestion.dateInterval {
      lines.append(dateInterval.start.formatted(date: .abbreviated, time: .shortened))
    }

    lines.append(contentsOf: suggestion.elements.map { "- \($0.shareSummary)" })
    return lines.joined(separator: "\n")
  }
}

extension SuggestionCardElement {

  fileprivate var shareSummary: String {
    switch self {
    case .contact(_, let name, _):
      return name
    case .eventPoster(_, let title, _, let eventStart, _, _, let placeName):
      return joined([title, placeName])
        ?? eventStart?.formatted(date: .abbreviated, time: .shortened)
        ?? String(localized: "Event")
    case .genericMedia(_, let title, let artist, let album, _, _):
      return joined([title, artist, album]) ?? String(localized: "Media")
    case .livePhoto(_, _, _, let date):
      if let date {
        return date.formatted(date: .abbreviated, time: .shortened)
      }
      return String(localized: "Live Photo")
    case .location(_, let location):
      return joined([location.place, location.city]) ?? String(localized: "Place")
    case .locationGroup(_, let locations):
      let names = locations.compactMap { joined([$0.place, $0.city]) }
      if let firstName = names.first, locations.count > 1 {
        return String(localized: "\(firstName) + \(locations.count - 1) places")
      }
      if let firstName = names.first {
        return firstName
      }
      return String(localized: "\(locations.count) places")
    case .motion(_, let steps, _, _, _):
      return String(localized: "\(steps) steps")
    case .photo(_, _, let date):
      if let date {
        return date.formatted(date: .abbreviated, time: .shortened)
      }
      return String(localized: "Photo")
    case .podcast(_, let episode, let show, _, _):
      return joined([episode, show]) ?? String(localized: "Podcast")
    case .reflection(_, let prompt):
      return prompt
    case .song(_, let title, let artist, let album, _, _):
      return joined([title, artist, album]) ?? String(localized: "Song")
    case .stateOfMind(_, let value, _):
      return String(
        localized: "State of Mind \(value.valence.formatted(.number.precision(.fractionLength(2))))"
      )
    case .video(_, _, let date):
      if let date {
        return date.formatted(date: .abbreviated, time: .shortened)
      }
      return String(localized: "Video")
    case .workout(_, let workout):
      return workout.shareSummary ?? String(localized: "Workout")
    case .workoutGroup(_, let group):
      if let duration = group.duration {
        return String(localized: "\(group.workouts.count) workouts - \(duration.formattedDuration)")
      }
      return String(localized: "\(group.workouts.count) workouts")
    }
  }

  private func joined(_ parts: [String?]) -> String? {
    let values = parts.compactMap(trimmed)
    return values.isEmpty ? nil : values.joined(separator: " - ")
  }

  private func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? nil : trimmedValue
  }
}

extension SuggestionCardWorkout {

  fileprivate var shareSummary: String? {
    let values = [
      details?.localizedName,
      details?.activeEnergyKilocalories.map { "\(Int($0)) kcal" },
      details?.distanceMeters.map { String(format: "%.1f km", $0 / 1000) },
    ].compactMap { trimmed($0) }

    guard values.isEmpty == false else {
      return nil
    }

    return values.joined(separator: " - ")
  }

  private func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? nil : trimmedValue
  }
}

extension TimeInterval {

  fileprivate var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}
