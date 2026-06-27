import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import Foundation
import JournalModel
import Observation
import SwiftUI

/// One editable card in the thread composer.
///
/// A reference type so editors bind to a card directly instead of looking it up
/// by `id` in an array, and so editing one card only re-renders the views that
/// observe *that* card.
///
/// Drafts keep capture values in their authored form (`CapturedPhoto`,
/// `AudioRecording`, `DoodleDrawing`, `BauhausGridArtwork`) until save time.
/// Persistence conversion is a boundary step, not composer state, so media
/// editors can reopen and continue editing the original values.
@MainActor
@Observable
final class ThreadDraftCard: Hashable, Sendable, Identifiable, Codable {

  private enum CodingKeys: String, CodingKey {
    case kind
    case text
    case photo
    case audio
    case doodle
    case bauhaus
    case location
  }

  /// Stable object identity used by SwiftUI presentation and transition APIs.
  nonisolated var id: ObjectIdentifier {
    ObjectIdentifier(self)
  }

  static func == (lhs: ThreadDraftCard, rhs: ThreadDraftCard) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }

  /// The modality this draft will become when persisted as a `Card`.
  var kind: Card.Kind

  /// Written content for text drafts. Media drafts do not treat this as a
  /// caption, but it stays available if the user switches the draft back to text.
  var text: String

  /// Captured still photo kept in the component's own value type until save.
  var photo: CapturedPhoto?

  /// Completed ambient recording kept in the component's own value type until
  /// save. The recording file is moved into the Journal media directory later.
  var audio: AudioRecording?

  /// Vector doodle kept editable while the draft is open.
  var doodle: DoodleDrawing?

  /// Geometric Bauhaus grid artwork kept editable while the draft is open.
  var bauhaus: BauhausGridArtwork?

  /// Current coordinate attached to this draft. `nil` means this card will be
  /// saved without location metadata.
  var location: Coordinate?

  /// Whether the composer can persist this draft in its current shape.
  var canSave: Bool {
    switch kind {
    case .text:
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case .photo:
      return photo != nil
    case .audio:
      return audio != nil
    case .doodle:
      return doodle != nil
    case .bauhaus:
      return bauhaus?.isEmpty == false
    @unknown default:
      return false
    }
  }

  /// Whether this draft is still the untouched text placeholder from the
  /// composer. Creation-level quick captures can reuse it instead of leaving a
  /// blank unsavable text card in front of the newly captured media.
  var isEmptyTextDraft: Bool {
    kind == .text
      && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && photo == nil
      && audio == nil
      && doodle == nil
      && bauhaus == nil
  }

  init(
    kind: Card.Kind = .text,
    text: String = "",
    photo: CapturedPhoto? = nil,
    audio: AudioRecording? = nil,
    doodle: DoodleDrawing? = nil,
    bauhaus: BauhausGridArtwork? = nil,
    location: Coordinate? = nil
  ) {
    self.kind = kind
    self.text = text
    self.photo = photo
    self.audio = audio
    self.doodle = doodle
    self.bauhaus = bauhaus
    self.location = location
  }

  required init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.kind = try container.decode(Card.Kind.self, forKey: .kind)
    self.text = try container.decode(String.self, forKey: .text)
    self.photo = try container.decodeIfPresent(CapturedPhoto.self, forKey: .photo)
    self.audio = try container.decodeIfPresent(AudioRecording.self, forKey: .audio)
    self.doodle = try container.decodeIfPresent(DoodleDrawing.self, forKey: .doodle)
    self.bauhaus = try container.decodeIfPresent(BauhausGridArtwork.self, forKey: .bauhaus)
    self.location = try container.decodeIfPresent(Coordinate.self, forKey: .location)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(photo, forKey: .photo)
    try container.encodeIfPresent(audio, forKey: .audio)
    try container.encodeIfPresent(doodle, forKey: .doodle)
    try container.encodeIfPresent(bauhaus, forKey: .bauhaus)
    try container.encodeIfPresent(location, forKey: .location)
  }

  /// Returns a detached copy for saving. The composer stays editable while the
  /// write path converts captured media, so persistence works from this stable
  /// snapshot instead of live view state.
  func savingSnapshot() -> ThreadDraftCardSnapshot {
    ThreadDraftCardSnapshot(
      kind: kind,
      text: text,
      photo: photo,
      audio: audio,
      doodle: doodle,
      bauhaus: bauhaus,
      location: location
    )
  }

  /// Stores a captured photo payload and switches the draft to photo mode.
  func setPhoto(_ photo: CapturedPhoto) {
    kind = .photo
    self.photo = photo
  }

  /// Stores a completed audio recording and switches the draft to audio mode.
  func setAudio(_ audio: AudioRecording) {
    kind = .audio
    self.audio = audio
  }

  /// Stores a vector doodle payload and switches the draft to doodle mode.
  func setDoodle(_ doodle: DoodleDrawing) {
    kind = .doodle
    self.doodle = doodle
  }

  /// Stores Bauhaus grid artwork and switches the draft to Bauhaus mode.
  func setBauhaus(_ artwork: BauhausGridArtwork) {
    kind = .bauhaus
    bauhaus = artwork
  }

  /// Clears the current doodle payload while keeping the draft in doodle mode.
  /// Used when the canvas is emptied after an automatic draft sync.
  func clearDoodle() {
    kind = .doodle
    doodle = nil
  }

  /// Clears the current Bauhaus artwork while keeping the draft in Bauhaus mode.
  /// Used when the grid is emptied after an automatic draft sync.
  func clearBauhaus() {
    kind = .bauhaus
    bauhaus = nil
  }

  /// Restores this draft to the untouched text placeholder used by the composer.
  /// Quick capture flows use this when a temporary media edit is cancelled or
  /// cleared after reusing the initial blank card.
  func resetToEmptyTextPlaceholder() {
    kind = .text
    text = ""
    photo = nil
    audio = nil
    doodle = nil
    bauhaus = nil
  }
}

/// Save-time copy of a draft card.
///
/// The snapshot freezes capture values and any already-attached coordinate,
/// then converts them into JournalModel's persistence input immediately before
/// the write.
struct ThreadDraftCardSnapshot: Sendable, Codable {

  var kind: Card.Kind
  var text: String
  var photo: CapturedPhoto?
  var audio: AudioRecording?
  var doodle: DoodleDrawing?
  var bauhaus: BauhausGridArtwork?
  var location: Coordinate?

  @MainActor
  func storeInput(doodleInkColor: Color) throws -> JournalStore.ThreadCardInput {
    switch kind {
    case .text:
      return JournalStore.ThreadCardInput(
        kind: .text,
        text: text,
        location: location
      )
    case .photo:
      guard let photo else { throw ThreadDraftCardSnapshotError.missingMediaPayload }
      return JournalStore.ThreadCardInput(
        kind: .photo,
        mediaData: photo.imageData,
        mediaThumbnail: photo.thumbnailData(),
        location: location
      )
    case .audio:
      guard let audio else { throw ThreadDraftCardSnapshotError.missingMediaPayload }
      return JournalStore.ThreadCardInput(
        kind: .audio,
        mediaFileURL: audio.fileURL,
        location: location
      )
    case .doodle:
      guard let doodle else { throw ThreadDraftCardSnapshotError.missingMediaPayload }
      return JournalStore.ThreadCardInput(
        kind: .doodle,
        mediaData: try JSONEncoder().encode(doodle),
        mediaThumbnail: doodle.image(inkColor: doodleInkColor)?.pngData(),
        location: location
      )
    case .bauhaus:
      guard let bauhaus, bauhaus.isEmpty == false else {
        throw ThreadDraftCardSnapshotError.missingMediaPayload
      }
      return JournalStore.ThreadCardInput(
        kind: .bauhaus,
        mediaData: try JSONEncoder().encode(bauhaus),
        mediaThumbnail: bauhaus.image()?.pngData(),
        location: location
      )
    @unknown default:
      throw ThreadDraftCardSnapshotError.unsupportedKind
    }
  }
}

enum ThreadDraftCardSnapshotError: Error {
  case missingMediaPayload
  case unsupportedKind
}
