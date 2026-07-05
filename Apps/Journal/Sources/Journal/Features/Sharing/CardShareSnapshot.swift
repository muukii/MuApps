import CaptureBauhaus
import Foundation
import JournalVault

/// Feature-local source values needed to create a share snapshot.
///
/// `SavedListView` builds this from its vault-backed display snapshot so the
/// sharing layer does not need access to private saved-list types or live
/// SwiftData models.
struct CardShareSource: Sendable, Equatable {
  let id: UUID
  let kind: JournalVault.Card.Kind
  let body: String
  let createdAt: Date
  let location: JournalVault.Coordinate?
  let attachment: CardShareAttachmentSource?
}

/// File-backed attachment values used by the share/export boundary.
struct CardShareAttachmentSource: Sendable, Equatable {
  let kind: JournalVault.Attachment.Kind
  let fileURL: URL
  let thumbnail: Data?
}

/// A detached, share-ready copy of one saved vault entry.
///
/// Sharing should not hold a live SwiftData model while rendering images or
/// videos. This snapshot reads the saved entry once, resolves its primary
/// attachment, and carries only value data into the export layer.
struct CardShareSnapshot: Identifiable, Sendable, Equatable {

  /// Stable card identity, reused for temporary export file names.
  var id: UUID

  /// The persisted card modality that determines how `content` should render.
  var kind: JournalVault.Card.Kind

  /// User-facing creation date shown on exported cards.
  var createdAt: Date

  /// Value payload used by image and video exporters.
  var content: CardShareContent

  /// Coordinate attached to the card, when the user opted in.
  var location: JournalVault.Coordinate?

  /// Builds a snapshot from saved vault-entry values.
  ///
  /// Media files are read from the selected vault's media directory when
  /// present. Missing files degrade to mirrored thumbnails or placeholders
  /// instead of failing, because sharing should still work for partially
  /// available CloudKit rows.
  init(source: CardShareSource) {
    let body = source.body.trimmingCharacters(in: .whitespacesAndNewlines)

    self.id = source.id
    self.kind = source.kind
    self.createdAt = source.createdAt
    self.location = source.location
    self.content = Self.makeContent(
      kind: source.kind,
      body: body,
      attachment: source.attachment
    )
  }

  private static func makeContent(
    kind: JournalVault.Card.Kind,
    body: String,
    attachment: CardShareAttachmentSource?
  ) -> CardShareContent {
    switch kind {
    case .text, .link:
      return .text(body)
    case .suggestion:
      return .text(SuggestionShareTextFormatter.text(from: fileData(for: attachment)))
    case .photo, .livePhoto:
      return .photo(imageData: fileData(for: attachment) ?? attachment?.thumbnail)
    case .video:
      return .photo(imageData: attachment?.thumbnail)
    case .audio:
      return .audio(fileURL: fileURL(for: attachment))
    case .doodle:
      return .doodle(
        drawingData: fileData(for: attachment),
        thumbnailData: attachment?.thumbnail
      )
    case .bauhaus:
      return .bauhaus(
        documentData: fileData(for: attachment),
        thumbnailData: attachment?.thumbnail
      )
    case .unknown:
      return .text(body)
    @unknown default:
      return .text(body)
    }
  }

  private static func fileData(for attachment: CardShareAttachmentSource?) -> Data? {
    guard let url = fileURL(for: attachment) else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func fileURL(for attachment: CardShareAttachmentSource?) -> URL? {
    guard let attachment else { return nil }
    guard FileManager.default.fileExists(atPath: attachment.fileURL.path) else {
      return nil
    }
    return attachment.fileURL
  }
}

private enum SuggestionShareTextFormatter {

  static func text(from data: Data?) -> String {
    guard let data,
          let suggestion = SuggestionCardPayload.decode(from: data) else {
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

private extension SuggestionCardElement {

  var shareSummary: String {
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
      return String(localized: "State of Mind \(value.valence.formatted(.number.precision(.fractionLength(2))))")
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

private extension SuggestionCardWorkout {

  var shareSummary: String? {
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

private extension TimeInterval {

  var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}

/// The mutually-exclusive share payload extracted from a `Card`.
///
/// Doodle carries both the encoded vector drawing and its mirrored thumbnail:
/// still-image and replay-video export can decode the vector timeline, while the
/// thumbnail remains a fallback when the full attachment file is unavailable.
enum CardShareContent: Sendable, Equatable {
  /// A written note.
  case text(String)

  /// A photo card, preferring full-size media bytes and falling back to the
  /// mirrored thumbnail when the full file is unavailable.
  case photo(imageData: Data?)

  /// An audio card, represented by its media file URL.
  case audio(fileURL: URL?)

  /// A doodle card with optional encoded `DoodleDrawing` JSON and thumbnail
  /// fallback.
  case doodle(drawingData: Data?, thumbnailData: Data?)

  /// A Bauhaus card with optional encoded `BauhausGridDocument` JSON and
  /// thumbnail fallback. Older final-only `BauhausGridArtwork` JSON decodes
  /// through the document's compatibility path.
  case bauhaus(documentData: Data?, thumbnailData: Data?)
}
