import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import CoreGraphics
import Foundation
import JournalVault
import MediaProcessing
import Observation
import UniformTypeIdentifiers

/// A selected video kept in a temporary file until the vault save commits a
/// copy in the selected vault's media directory.
struct CapturedVideo: Sendable, Equatable, Codable {
  var fileURL: URL
  var thumbnailData: Data?
  var pixelSize: CGSize
  var duration: TimeInterval
  var contentTypeIdentifier: String?
  var byteSize: Int?

  init(
    fileURL: URL,
    thumbnailData: Data? = nil,
    pixelSize: CGSize = .zero,
    duration: TimeInterval = 0,
    contentTypeIdentifier: String? = nil,
    byteSize: Int? = nil
  ) {
    self.fileURL = fileURL
    self.thumbnailData = thumbnailData
    self.pixelSize = pixelSize
    self.duration = duration
    self.contentTypeIdentifier = contentTypeIdentifier
    self.byteSize = byteSize
  }
}

extension CapturedVideo {
  fileprivate var pixelWidth: Int? { pixelSize.nonZeroPixelWidth }
  fileprivate var pixelHeight: Int? { pixelSize.nonZeroPixelHeight }
}

/// A selected Live Photo represented by its required still image and paired
/// movie resources.
///
/// `PHLivePhoto` itself is not persisted. The Photos import boundary extracts
/// the durable resource files, then the vault save writes them as sibling
/// `AttachmentResource` rows so CloudKit sync/export can reason about both.
struct CapturedLivePhoto: Sendable, Equatable, Codable {
  var stillImageData: Data
  var pairedVideoFileURL: URL
  var thumbnailData: Data?
  var pixelSize: CGSize
  var duration: TimeInterval
  var stillImageContentTypeIdentifier: String?
  var pairedVideoContentTypeIdentifier: String?
  var stillImageByteSize: Int?
  var pairedVideoByteSize: Int?

  init(
    stillImageData: Data,
    pairedVideoFileURL: URL,
    thumbnailData: Data? = nil,
    pixelSize: CGSize = .zero,
    duration: TimeInterval = 0,
    stillImageContentTypeIdentifier: String? = nil,
    pairedVideoContentTypeIdentifier: String? = nil,
    stillImageByteSize: Int? = nil,
    pairedVideoByteSize: Int? = nil
  ) {
    self.stillImageData = stillImageData
    self.pairedVideoFileURL = pairedVideoFileURL
    self.thumbnailData = thumbnailData
    self.pixelSize = pixelSize
    self.duration = duration
    self.stillImageContentTypeIdentifier = stillImageContentTypeIdentifier
    self.pairedVideoContentTypeIdentifier = pairedVideoContentTypeIdentifier
    self.stillImageByteSize = stillImageByteSize
    self.pairedVideoByteSize = pairedVideoByteSize
  }
}

extension CapturedLivePhoto {
  fileprivate var pixelWidth: Int? { pixelSize.nonZeroPixelWidth }
  fileprivate var pixelHeight: Int? { pixelSize.nonZeroPixelHeight }
}

extension CGSize {
  fileprivate var nonZeroPixelWidth: Int? {
    width > 0 ? Int(width.rounded()) : nil
  }

  fileprivate var nonZeroPixelHeight: Int? {
    height > 0 ? Int(height.rounded()) : nil
  }
}

/// One editable Journal card draft.
///
/// A reference type so editors bind to a draft directly instead of looking it up
/// by `id` in an array, and so editing one card only re-renders the views that
/// observe *that* draft.
///
/// Drafts keep capture values in their authored form (`CapturedPhoto`,
/// `AudioRecording`, `DoodleDrawing`, `BauhausGridDocument`) until save time.
/// Persistence conversion is a boundary step, not creation-screen state, so the
/// same model can drive creation, saved-entry editing, and previews.
@MainActor
@Observable
final class CardEditDraft: Hashable, Sendable, Identifiable, Codable {

  private enum CodingKeys: String, CodingKey {
    case displayID
    case createdAt
    case kind
    case text
    case completedAt
    case photo
    case video
    case livePhoto
    case audio
    case suggestion
    case suggestionMediaFileURLsByResourceID
    case doodle
    case bauhaus
    case location
  }

  /// Stable object identity used by SwiftUI presentation and transition APIs.
  nonisolated var id: ObjectIdentifier {
    ObjectIdentifier(self)
  }

  /// Stable value identity used by non-editing card renderers.
  ///
  /// SwiftUI editing flows use object identity (`id`) so bindings stay attached
  /// to this reference, while entry-style display components need a value id
  /// like persisted `Card` rows have.
  let displayID: UUID

  /// Creation time shown by entry-style card chrome before the draft is saved.
  let createdAt: Date

  static func == (lhs: CardEditDraft, rhs: CardEditDraft) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }

  /// The modality this draft will become when persisted as a `Card`.
  var kind: Card.Kind

  /// Written content for text and Todo drafts. Media drafts do not treat this
  /// as a caption. Link drafts use this same body slot as raw URL text until
  /// save time normalizes it.
  var text: String

  /// Text projection used by the compact creation composer.
  ///
  /// A complete HTTP(S) URL arriving as the first value promotes the untouched
  /// text placeholder to Link. Once any text has been entered, later URLs remain
  /// ordinary text so writing a sentence never changes modality underneath the
  /// user.
  var composerText: String {
    get { text }
    set {
      guard isEmptyTextDraft,
        text.isEmpty,
        Self.isEntireWebURL(newValue)
      else {
        text = newValue
        return
      }

      setLinkURLString(newValue)
    }
  }

  /// Completion timestamp retained while a saved Todo is edited.
  /// New Todo drafts leave this `nil`, and non-Todo drafts ignore it.
  var completedAt: Date?

  /// Normalized URL for a link draft, or `nil` while the typed value is not a
  /// previewable web URL.
  var linkURL: JournalLinkURL? {
    JournalLinkURL(text)
  }

  /// Captured still photo kept in the component's own value type until save.
  var photo: CapturedPhoto?

  /// Selected video kept in a temporary file until a successful save cleans it up.
  var video: CapturedVideo?

  /// Selected Live Photo kept as still + paired movie resources until save.
  var livePhoto: CapturedLivePhoto?

  /// Completed ambient recording kept in the component's own value type until
  /// save. The recording file is moved into the Journal media directory later.
  var audio: AudioRecording?

  /// Selected Journaling Suggestion snapshot kept as value data until save.
  ///
  /// The device-only `CaptureSuggestions` framework stays at the picker
  /// boundary. Drafts store the vault-owned payload type so saved previews and
  /// widgets can decode suggestion cards without linking that system framework.
  var suggestion: SuggestionCardPayload?

  /// Local source files for media already copied into a saved suggestion card.
  ///
  /// The durable `SuggestionCardPayload` records resource ids, not local file
  /// paths. Saved-entry editing fills this map so replacing the card can copy
  /// the existing vault files into the new attachment resource set.
  var suggestionMediaFileURLsByResourceID: [UUID: URL]

  /// Vector doodle kept editable while the draft is open.
  var doodle: DoodleDrawing?

  /// Geometric Bauhaus document kept editable while the draft is open.
  ///
  /// The document carries the final grid plus optional authored replay timeline.
  /// Old final-only payloads decode with `replay == nil`, so draft editing never
  /// invents a fake history for synced or pre-replay cards.
  var bauhaus: BauhausGridDocument?

  /// Current coordinate attached to this draft. `nil` means this card will be
  /// saved without location metadata.
  var location: Coordinate?

  /// Whether the composer can persist this draft in its current shape.
  var canSave: Bool {
    switch kind {
    case .text, .todo:
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case .link:
      return linkURL != nil
    case .file:
      // Files arrive through the Share extension and are not authored or
      // replaced by the in-app draft editor.
      return false
    case .photo:
      return photo != nil
    case .video:
      return video != nil
    case .livePhoto:
      return livePhoto != nil
    case .audio:
      return audio != nil
    case .suggestion:
      return suggestion != nil
    case .doodle:
      return doodle != nil
    case .bauhaus:
      return bauhaus?.artwork.isEmpty == false
    case .unknown:
      return false
    @unknown default:
      return false
    }
  }

  /// Whether the currently selected modality contains no authored input at all.
  ///
  /// This differs from `canSave`: an invalid but non-empty link is still authored
  /// input and must not be silently discarded when its editor closes.
  var isCurrentKindContentEmpty: Bool {
    switch kind {
    case .text, .todo, .link:
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .file:
      return false
    case .photo:
      return photo == nil
    case .video:
      return video == nil
    case .livePhoto:
      return livePhoto == nil
    case .audio:
      return audio == nil
    case .suggestion:
      return suggestion == nil
    case .doodle:
      return doodle == nil
    case .bauhaus:
      return bauhaus?.artwork.isEmpty ?? true
    case .unknown:
      return false
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
      && completedAt == nil
      && photo == nil
      && video == nil
      && livePhoto == nil
      && audio == nil
      && suggestion == nil
      && suggestionMediaFileURLsByResourceID.isEmpty
      && doodle == nil
      && bauhaus == nil
  }

  init(
    displayID: UUID = UUID(),
    createdAt: Date = Date(),
    kind: Card.Kind = .text,
    text: String = "",
    completedAt: Date? = nil,
    photo: CapturedPhoto? = nil,
    video: CapturedVideo? = nil,
    livePhoto: CapturedLivePhoto? = nil,
    audio: AudioRecording? = nil,
    suggestion: SuggestionCardPayload? = nil,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:],
    doodle: DoodleDrawing? = nil,
    bauhaus: BauhausGridDocument? = nil,
    location: Coordinate? = nil
  ) {
    self.displayID = displayID
    self.createdAt = createdAt
    self.kind = kind
    self.text = text
    self.completedAt = kind == .todo ? completedAt : nil
    self.photo = photo
    self.video = video
    self.livePhoto = livePhoto
    self.audio = audio
    self.suggestion = suggestion
    self.suggestionMediaFileURLsByResourceID = suggestionMediaFileURLsByResourceID
    self.doodle = doodle
    self.bauhaus = bauhaus
    self.location = location
  }

  required init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.displayID = try container.decodeIfPresent(UUID.self, forKey: .displayID) ?? UUID()
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    let decodedKind = try container.decode(Card.Kind.self, forKey: .kind)
    self.kind = decodedKind
    self.text = try container.decode(String.self, forKey: .text)
    let decodedCompletedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    self.completedAt = decodedKind == .todo ? decodedCompletedAt : nil
    self.photo = try container.decodeIfPresent(CapturedPhoto.self, forKey: .photo)
    self.video = try container.decodeIfPresent(CapturedVideo.self, forKey: .video)
    self.livePhoto = try container.decodeIfPresent(CapturedLivePhoto.self, forKey: .livePhoto)
    self.audio = try container.decodeIfPresent(AudioRecording.self, forKey: .audio)
    self.suggestion = try container.decodeIfPresent(SuggestionCardPayload.self, forKey: .suggestion)
    self.suggestionMediaFileURLsByResourceID =
      try container.decodeIfPresent(
        [UUID: URL].self,
        forKey: .suggestionMediaFileURLsByResourceID
      ) ?? [:]
    self.doodle = try container.decodeIfPresent(DoodleDrawing.self, forKey: .doodle)
    self.bauhaus = try container.decodeIfPresent(BauhausGridDocument.self, forKey: .bauhaus)
    self.location = try container.decodeIfPresent(Coordinate.self, forKey: .location)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(displayID, forKey: .displayID)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(kind, forKey: .kind)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
    try container.encodeIfPresent(photo, forKey: .photo)
    try container.encodeIfPresent(video, forKey: .video)
    try container.encodeIfPresent(livePhoto, forKey: .livePhoto)
    try container.encodeIfPresent(audio, forKey: .audio)
    try container.encodeIfPresent(suggestion, forKey: .suggestion)
    if suggestionMediaFileURLsByResourceID.isEmpty == false {
      try container.encode(
        suggestionMediaFileURLsByResourceID, forKey: .suggestionMediaFileURLsByResourceID)
    }
    try container.encodeIfPresent(doodle, forKey: .doodle)
    try container.encodeIfPresent(bauhaus, forKey: .bauhaus)
    try container.encodeIfPresent(location, forKey: .location)
  }

  /// Returns a detached copy for saving. The composer stays editable while the
  /// write path converts captured media, so persistence works from this stable
  /// snapshot instead of live view state.
  func savingSnapshot() -> CardEditDraftSnapshot {
    CardEditDraftSnapshot(
      kind: kind,
      text: text,
      completedAt: completedAt,
      photo: photo,
      video: video,
      livePhoto: livePhoto,
      audio: audio,
      suggestion: suggestion,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID,
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

  /// Stores a selected video payload and switches the draft to video mode.
  func setVideo(_ video: CapturedVideo) {
    kind = .video
    self.video = video
  }

  /// Stores a selected Live Photo payload and switches the draft to Live Photo mode.
  func setLivePhoto(_ livePhoto: CapturedLivePhoto) {
    kind = .livePhoto
    self.livePhoto = livePhoto
  }

  /// Stores raw URL text and switches the draft to link mode.
  func setLinkURLString(_ urlString: String) {
    kind = .link
    text = urlString
  }

  /// Switches an empty composer draft to a new, incomplete Todo.
  func setTodo() {
    kind = .todo
    completedAt = nil
  }

  /// Stores a completed audio recording and switches the draft to audio mode.
  func setAudio(_ audio: AudioRecording) {
    kind = .audio
    self.audio = audio
  }

  /// Stores a selected Journaling Suggestion and switches the draft to
  /// suggestion mode.
  func setSuggestion(_ suggestion: SuggestionCardPayload) {
    kind = .suggestion
    self.suggestion = suggestion
    suggestionMediaFileURLsByResourceID = [:]
  }

  /// Stores a vector doodle payload and switches the draft to doodle mode.
  func setDoodle(_ doodle: DoodleDrawing) {
    kind = .doodle
    self.doodle = doodle
  }

  /// Stores a Bauhaus document and switches the draft to Bauhaus mode.
  func setBauhaus(_ document: BauhausGridDocument) {
    kind = .bauhaus
    bauhaus = document
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
    completedAt = nil
    photo = nil
    video = nil
    livePhoto = nil
    audio = nil
    suggestion = nil
    suggestionMediaFileURLsByResourceID = [:]
    doodle = nil
    bauhaus = nil
    location = nil
  }

  /// Returns whether the complete input is one detected HTTP(S) web URL.
  ///
  /// `JournalLinkURL` intentionally accepts forgiving host-like values for the
  /// explicit Link editor. Automatic promotion is stricter so a plain word or
  /// email address cannot unexpectedly replace the text composer.
  private static func isEntireWebURL(_ input: String) -> Bool {
    JournalLinkURL(entireWebURL: input) != nil
  }
}

/// Save-time copy of a draft card.
///
/// The snapshot freezes capture values and any already-attached coordinate,
/// then converts them into vault persistence input immediately before the write.
struct CardEditDraftSnapshot: Sendable, Codable {

  var kind: Card.Kind
  var text: String
  var completedAt: Date?
  var photo: CapturedPhoto?
  var video: CapturedVideo?
  var livePhoto: CapturedLivePhoto?
  var audio: AudioRecording?
  var suggestion: SuggestionCardPayload?
  var suggestionMediaFileURLsByResourceID: [UUID: URL]
  var doodle: DoodleDrawing?
  var bauhaus: BauhausGridDocument?
  var location: Coordinate?

  @MainActor
  func vaultDraft() throws -> VaultContentStore.CardDraft {
    switch kind {
    case .text:
      return VaultContentStore.CardDraft(
        kind: .text,
        text: text,
        location: location
      )
    case .todo:
      return VaultContentStore.CardDraft(
        kind: .todo,
        text: text,
        completedAt: completedAt,
        location: location
      )
    case .link:
      guard let linkURL = JournalLinkURL(text) else {
        throw CardEditDraftSnapshotError.invalidLinkURL
      }
      return VaultContentStore.CardDraft(
        kind: .link,
        text: linkURL.storageString,
        location: location
      )
    case .file:
      throw CardEditDraftSnapshotError.unsupportedKind
    case .photo:
      guard let photo else { throw CardEditDraftSnapshotError.missingMediaPayload }
      let thumbnail = try? MediaThumbnailGenerator.imageThumbnail(from: photo.imageData).data
      // Keep display dimensions on the original resource so list placeholders
      // and CloudKit peers know the photo geometry before decoding its JPEG.
      return VaultContentStore.CardDraft(
        kind: .photo,
        mediaResources: [
          VaultContentStore.AttachmentResourceDraft(
            role: .originalImage,
            data: photo.imageData,
            byteSize: photo.imageData.count,
            contentType: "public.jpeg",
            pixelWidth: photo.pixelSize.nonZeroPixelWidth,
            pixelHeight: photo.pixelSize.nonZeroPixelHeight
          )
        ],
        thumbnail: thumbnail,
        location: location
      )
    case .video:
      guard let video else { throw CardEditDraftSnapshotError.missingMediaPayload }
      let thumbnail =
        video.thumbnailData
        ?? (try? MediaThumbnailGenerator.videoThumbnail(from: video.fileURL).data)
      return VaultContentStore.CardDraft(
        kind: .video,
        mediaResources: [
          VaultContentStore.AttachmentResourceDraft(
            role: .originalVideo,
            fileURL: video.fileURL,
            byteSize: video.byteSize,
            contentType: video.contentTypeIdentifier ?? "public.mpeg-4",
            pixelWidth: video.pixelWidth,
            pixelHeight: video.pixelHeight,
            duration: video.duration
          )
        ],
        thumbnail: thumbnail,
        location: location
      )
    case .livePhoto:
      guard let livePhoto else { throw CardEditDraftSnapshotError.missingMediaPayload }
      let thumbnail =
        livePhoto.thumbnailData
        ?? (try? MediaThumbnailGenerator.imageThumbnail(from: livePhoto.stillImageData).data)
      return VaultContentStore.CardDraft(
        kind: .livePhoto,
        mediaResources: [
          VaultContentStore.AttachmentResourceDraft(
            role: .stillImage,
            data: livePhoto.stillImageData,
            byteSize: livePhoto.stillImageByteSize,
            contentType: livePhoto.stillImageContentTypeIdentifier,
            pixelWidth: livePhoto.pixelWidth,
            pixelHeight: livePhoto.pixelHeight
          ),
          VaultContentStore.AttachmentResourceDraft(
            role: .pairedVideo,
            fileURL: livePhoto.pairedVideoFileURL,
            byteSize: livePhoto.pairedVideoByteSize,
            contentType: livePhoto.pairedVideoContentTypeIdentifier ?? "public.mpeg-4",
            pixelWidth: livePhoto.pixelWidth,
            pixelHeight: livePhoto.pixelHeight,
            duration: livePhoto.duration
          ),
        ],
        thumbnail: thumbnail,
        location: location
      )
    case .audio:
      guard let audio else { throw CardEditDraftSnapshotError.missingMediaPayload }
      return VaultContentStore.CardDraft(
        kind: .audio,
        mediaResources: [
          VaultContentStore.AttachmentResourceDraft(
            role: .audio,
            fileURL: audio.fileURL,
            contentType: "public.mpeg-4-audio",
            duration: audio.duration
          )
        ],
        location: location
      )
    case .suggestion:
      guard let suggestion else { throw CardEditDraftSnapshotError.missingSuggestionPayload }
      let resourceDrafts = try SuggestionCardResourceStager.resourceDrafts(
        for: suggestion,
        sourceFilesByResourceID: suggestionMediaFileURLsByResourceID
      )
      return VaultContentStore.CardDraft(
        kind: .suggestion,
        mediaResources: resourceDrafts,
        location: location
      )
    case .doodle:
      guard let doodle else { throw CardEditDraftSnapshotError.missingMediaPayload }
      let doodleData = try JSONEncoder().encode(doodle)
      // Keep the authored canvas size on the resource so saved-list placeholders
      // know the drawing's geometry before its JSON decodes.
      return VaultContentStore.CardDraft(
        kind: .doodle,
        mediaResources: [
          VaultContentStore.AttachmentResourceDraft(
            role: .authoredJSON,
            data: doodleData,
            byteSize: doodleData.count,
            contentType: "public.json",
            pixelWidth: doodle.canvasSize.nonZeroPixelWidth,
            pixelHeight: doodle.canvasSize.nonZeroPixelHeight
          )
        ],
        location: location
      )
    case .bauhaus:
      guard let bauhaus, bauhaus.artwork.isEmpty == false else {
        throw CardEditDraftSnapshotError.missingMediaPayload
      }
      return VaultContentStore.CardDraft(
        kind: .bauhaus,
        mediaData: try JSONEncoder().encode(bauhaus),
        location: location
      )
    case .unknown:
      throw CardEditDraftSnapshotError.unsupportedKind
    @unknown default:
      throw CardEditDraftSnapshotError.unsupportedKind
    }
  }

  /// Removes app-owned temporary media after persistence has committed.
  ///
  /// Vault persistence consumes these files only after its transaction commits;
  /// explicit discard uses this helper when no save will take ownership.
  func removeTemporaryMediaFiles() {
    let fileURLs = Set(
      [
        video?.fileURL,
        livePhoto?.pairedVideoFileURL,
        audio?.fileURL,
      ].compactMap { $0 }
    )

    for fileURL in fileURLs {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }
}

private enum SuggestionCardResourceStager {

  static func resourceDrafts(
    for suggestion: SuggestionCardPayload,
    sourceFilesByResourceID: [UUID: URL]
  ) throws -> [VaultContentStore.AttachmentResourceDraft] {
    var stagedSuggestion = suggestion
    var mediaResourceDrafts: [VaultContentStore.AttachmentResourceDraft] = []

    for index in stagedSuggestion.mediaResources.indices {
      let media = stagedSuggestion.mediaResources[index]
      guard
        let sourceURL = media.sourceURL(
          in: suggestion,
          sourceFilesByResourceID: sourceFilesByResourceID
        ),
        sourceURL.isFileURL,
        FileManager.default.fileExists(atPath: sourceURL.path)
      else {
        stagedSuggestion.mediaResources[index].resourceID = nil
        continue
      }

      let resourceID = UUID()
      stagedSuggestion.mediaResources[index].resourceID = resourceID
      mediaResourceDrafts.append(
        VaultContentStore.AttachmentResourceDraft(
          id: resourceID,
          role: media.kind.attachmentResourceRole,
          fileURL: sourceURL,
          fileTransferMode: .copy,
          contentType: media.contentType
            ?? sourceURL.inferredContentTypeIdentifier
            ?? media.kind.fallbackContentType
        )
      )
    }

    let authoredJSONData = try stagedSuggestion.encodedData()
    return [
      VaultContentStore.AttachmentResourceDraft(
        role: .authoredJSON,
        data: authoredJSONData,
        byteSize: authoredJSONData.count,
        contentType: "public.json"
      )
    ] + mediaResourceDrafts
  }
}

extension SuggestionCardMediaResource {

  fileprivate func sourceURL(
    in suggestion: SuggestionCardPayload,
    sourceFilesByResourceID: [UUID: URL]
  ) -> URL? {
    if let resourceID,
      let fileURL = sourceFilesByResourceID[resourceID]
    {
      return fileURL
    }

    guard let element = suggestion.elements.first(where: { $0.id == elementID }) else {
      return nil
    }

    switch (kind, element) {
    case (.contactPhoto, .contact(_, _, let photoURL)):
      return photoURL
    case (.eventPosterImage, .eventPoster(_, _, let imageURL, _, _, _, _)):
      return imageURL
    case (.genericMediaAppIcon, .genericMedia(_, _, _, _, _, let appIconURL)):
      return appIconURL
    case (.livePhotoImage, .livePhoto(_, let imageURL, _, _)):
      return imageURL
    case (.livePhotoVideo, .livePhoto(_, _, let videoURL, _)):
      return videoURL
    case (.motionIcon, .motion(_, _, _, let iconURL, _)):
      return iconURL
    case (.photoImage, .photo(_, let imageURL, _)):
      return imageURL
    case (.podcastArtwork, .podcast(_, _, _, let artworkURL, _)):
      return artworkURL
    case (.songArtwork, .song(_, _, _, _, let artworkURL, _)):
      return artworkURL
    case (.stateOfMindIcon, .stateOfMind(_, _, let iconURL)):
      return iconURL
    case (.video, .video(_, let videoURL, _)):
      return videoURL
    case (.workoutIcon, .workout(_, let workout)):
      return workout.iconURL
    case (.workoutGroupIcon, .workoutGroup(_, let group)):
      return group.iconURL
    default:
      return nil
    }
  }
}

extension SuggestionCardMediaResource.Kind {

  fileprivate var attachmentResourceRole: AttachmentResource.Role {
    switch self {
    case .livePhotoVideo, .video:
      return .suggestionVideo
    case .contactPhoto,
      .eventPosterImage,
      .genericMediaAppIcon,
      .livePhotoImage,
      .motionIcon,
      .photoImage,
      .podcastArtwork,
      .songArtwork,
      .stateOfMindIcon,
      .workoutIcon,
      .workoutGroupIcon:
      return .suggestionImage
    }
  }

  fileprivate var fallbackContentType: String {
    switch self {
    case .livePhotoVideo, .video:
      return "public.mpeg-4"
    case .contactPhoto,
      .eventPosterImage,
      .genericMediaAppIcon,
      .livePhotoImage,
      .motionIcon,
      .photoImage,
      .podcastArtwork,
      .songArtwork,
      .stateOfMindIcon,
      .workoutIcon,
      .workoutGroupIcon:
      return "public.jpeg"
    }
  }
}

extension URL {

  fileprivate var inferredContentTypeIdentifier: String? {
    UTType(filenameExtension: pathExtension)?.identifier
  }
}

enum CardEditDraftSnapshotError: Error {
  case missingMediaPayload
  case missingSuggestionPayload
  case invalidLinkURL
  case unsupportedKind
}

/// Creation-facing name kept while the shared edit draft is adopted across the app.
typealias ThreadDraftCard = CardEditDraft

/// Creation-facing snapshot name kept for call sites that still speak in drafts.
typealias ThreadDraftCardSnapshot = CardEditDraftSnapshot

/// Creation-facing error name kept while save-time conversion is generalized.
typealias ThreadDraftCardSnapshotError = CardEditDraftSnapshotError
