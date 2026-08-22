import AppUIComponents
import CaptureAudio
import Foundation
import JournalVault
import Testing

@testable import Tinycurve

@Suite("Saved card to entry content")
@MainActor
struct SavedEntryContentTests {

  @Test("Body-backed cards convert directly without an attachment model")
  func bodyBackedCardsConvertDirectly() throws {
    let store = try makeStore()
    let completedAt = Date(timeIntervalSince1970: 42)

    #expect(
      EntryContent(
        card: JournalVault.Card(kind: .text, body: "A note"),
        store: store
      ) == .text("A note")
    )
    #expect(
      EntryContent(
        card: JournalVault.Card(
          kind: .todo,
          body: "Call home",
          completedAt: completedAt
        ),
        store: store
      )
        == .todo(
          TodoContentSource(text: "Call home", completedAt: completedAt)
        )
    )
    #expect(
      EntryContent(
        card: JournalVault.Card(kind: .link, body: "https://example.com"),
        store: store
      ) == .link("https://example.com")
    )
    #expect(
      EntryContent(
        card: JournalVault.Card(kind: .unknown),
        store: store
      ) == .unknown
    )
  }

  @Test("File and raster media preserve resolved resource metadata")
  func fileAndRasterMediaPreserveResourceMetadata() throws {
    let store = try makeStore()

    let fileCard = JournalVault.Card(kind: .file, body: "Archive.zip")
    let fileAttachmentID = UUID()
    let fileResource = resource(
      attachmentID: fileAttachmentID,
      role: .file,
      byteSize: 2_048,
      contentType: "public.zip-archive",
      localFileRevision: 2
    )
    attach(
      to: fileCard,
      id: fileAttachmentID,
      kind: .file,
      primaryResource: fileResource
    )

    guard case .file(let file) = EntryContent(card: fileCard, store: store)
    else {
      Issue.record("Expected file content")
      return
    }
    #expect(file.displayName == "Archive.zip")
    #expect(file.fileURL == store.fileURL(for: fileResource))
    #expect(file.contentType == "public.zip-archive")
    #expect(file.byteSize == 2_048)

    let photoCard = JournalVault.Card(kind: .photo)
    let photoAttachmentID = UUID()
    let photoResource = resource(
      attachmentID: photoAttachmentID,
      role: .originalImage,
      pixelWidth: 1_200,
      pixelHeight: 800,
      localFileRevision: 7
    )
    attach(
      to: photoCard,
      id: photoAttachmentID,
      kind: .photo,
      primaryResource: photoResource
    )

    guard case .photo(let photo) = EntryContent(card: photoCard, store: store)
    else {
      Issue.record("Expected photo content")
      return
    }
    #expect(photo.fileURL == store.fileURL(for: photoResource))
    #expect(photo.fileRevision == 7)
    #expect(photo.displayAspectRatio == 1.5)

    let videoCard = JournalVault.Card(kind: .video)
    let videoAttachmentID = UUID()
    let videoResource = resource(
      attachmentID: videoAttachmentID,
      role: .originalVideo,
      pixelWidth: 1_920,
      pixelHeight: 1_080,
      localFileRevision: 11
    )
    attach(
      to: videoCard,
      id: videoAttachmentID,
      kind: .video,
      primaryResource: videoResource
    )

    guard case .video(let video) = EntryContent(card: videoCard, store: store)
    else {
      Issue.record("Expected video content")
      return
    }
    #expect(video.fileURL == store.fileURL(for: videoResource))
    #expect(video.fileRevision == 11)
    let videoAspectRatio = try #require(video.displayAspectRatio)
    #expect(abs(videoAspectRatio - 16.0 / 9.0) < 0.000_001)
  }

  @Test("Live Photo resolves its primary still and paired video directly")
  func livePhotoResolvesPairedResources() throws {
    let store = try makeStore()
    let card = JournalVault.Card(kind: .livePhoto)
    let attachmentID = UUID()
    let still = resource(
      attachmentID: attachmentID,
      role: .stillImage,
      pixelWidth: 4_032,
      pixelHeight: 3_024,
      localFileRevision: 3
    )
    let pairedVideo = resource(
      attachmentID: attachmentID,
      role: .pairedVideo,
      localFileRevision: 5
    )
    attach(
      to: card,
      id: attachmentID,
      kind: .livePhoto,
      primaryResource: still,
      resources: [pairedVideo, still]
    )

    guard case .livePhoto(let livePhoto) = EntryContent(card: card, store: store)
    else {
      Issue.record("Expected Live Photo content")
      return
    }

    #expect(livePhoto.fileURL == store.fileURL(for: still))
    #expect(livePhoto.pairedVideoFileURL == store.fileURL(for: pairedVideo))
    #expect(livePhoto.fileRevision == 8)
    let livePhotoAspectRatio = try #require(livePhoto.displayAspectRatio)
    #expect(abs(livePhotoAspectRatio - 4.0 / 3.0) < 0.000_001)
  }

  @Test("Audio and suggestion derive their specialized resource values")
  func audioAndSuggestionDeriveSpecializedValues() throws {
    let store = try makeStore()
    let waveform = AudioWaveform(
      normalizedLevels: [0, 0.5, 1],
      sampleInterval: 0.05
    )
    let audioCard = JournalVault.Card(kind: .audio)
    let audioAttachmentID = UUID()
    let audioResource = resource(
      attachmentID: audioAttachmentID,
      role: .audio,
      duration: 4.25,
      waveformData: try waveform.encodedData()
    )
    attach(
      to: audioCard,
      id: audioAttachmentID,
      kind: .audio,
      primaryResource: audioResource
    )

    guard case .audio(let audio) = EntryContent(card: audioCard, store: store)
    else {
      Issue.record("Expected audio content")
      return
    }
    #expect(audio.fileURL == store.fileURL(for: audioResource))
    #expect(audio.waveformLevels == waveform.levels)
    #expect(audio.duration == 4.25)

    let suggestionCard = JournalVault.Card(kind: .suggestion)
    let suggestionAttachmentID = UUID()
    let authoredJSON = resource(
      attachmentID: suggestionAttachmentID,
      role: .authoredJSON,
      localFileRevision: 1
    )
    let image = resource(
      attachmentID: suggestionAttachmentID,
      role: .suggestionImage,
      localFileRevision: 2
    )
    let video = resource(
      attachmentID: suggestionAttachmentID,
      role: .suggestionVideo,
      localFileRevision: 4
    )
    attach(
      to: suggestionCard,
      id: suggestionAttachmentID,
      kind: .suggestion,
      primaryResource: authoredJSON,
      resources: [video, authoredJSON, image]
    )

    guard
      case .suggestion(let suggestion) = EntryContent(
        card: suggestionCard,
        store: store
      )
    else {
      Issue.record("Expected suggestion content")
      return
    }
    #expect(suggestion.fileURL == store.fileURL(for: authoredJSON))
    #expect(suggestion.fileRevision == 7)
    #expect(
      suggestion.mediaFileURLsByResourceID == [
        image.id: store.fileURL(for: image),
        video.id: store.fileURL(for: video),
      ]
    )
  }

  @Test("Authored JSON cards preserve revisions and media geometry")
  func authoredJSONCardsPreserveRevisionAndGeometry() throws {
    let store = try makeStore()
    let doodleCard = JournalVault.Card(kind: .doodle)
    let doodleAttachmentID = UUID()
    let doodleResource = resource(
      attachmentID: doodleAttachmentID,
      role: .authoredJSON,
      pixelWidth: 900,
      pixelHeight: 600,
      localFileRevision: 12
    )
    attach(
      to: doodleCard,
      id: doodleAttachmentID,
      kind: .doodle,
      primaryResource: doodleResource
    )

    guard
      case .doodle(let doodle) = EntryContent(
        card: doodleCard,
        store: store
      )
    else {
      Issue.record("Expected doodle content")
      return
    }
    #expect(doodle.fileURL == store.fileURL(for: doodleResource))
    #expect(doodle.fileRevision == 12)
    #expect(doodle.displayAspectRatio == 1.5)

    let bauhausCard = JournalVault.Card(kind: .bauhaus)
    let bauhausAttachmentID = UUID()
    let bauhausResource = resource(
      attachmentID: bauhausAttachmentID,
      role: .authoredJSON,
      localFileRevision: 13
    )
    attach(
      to: bauhausCard,
      id: bauhausAttachmentID,
      kind: .bauhaus,
      primaryResource: bauhausResource
    )

    guard
      case .bauhaus(let bauhaus) = EntryContent(
        card: bauhausCard,
        store: store
      )
    else {
      Issue.record("Expected Bauhaus content")
      return
    }
    #expect(bauhaus.fileURL == store.fileURL(for: bauhausResource))
    #expect(bauhaus.fileRevision == 13)
  }

  @Test("Missing or mismatched attachments produce typed placeholders")
  func missingOrMismatchedAttachmentsProducePlaceholders() throws {
    let store = try makeStore()
    let photoCard = JournalVault.Card(kind: .photo)
    let attachmentID = UUID()
    let videoResource = resource(
      attachmentID: attachmentID,
      role: .originalVideo,
      localFileRevision: 99
    )
    attach(
      to: photoCard,
      id: attachmentID,
      kind: .video,
      primaryResource: videoResource
    )

    guard case .photo(let photo) = EntryContent(card: photoCard, store: store)
    else {
      Issue.record("Expected a typed photo placeholder")
      return
    }
    #expect(photo.fileURL == nil)
    #expect(photo.fileRevision == 0)
    #expect(photo.displayAspectRatio == nil)

    guard
      case .file(let file) = EntryContent(
        card: JournalVault.Card(kind: .file, body: "Missing.dat"),
        store: store
      )
    else {
      Issue.record("Expected a typed file placeholder")
      return
    }
    #expect(file.displayName == "Missing.dat")
    #expect(file.fileURL == nil)
    #expect(file.contentType == nil)
    #expect(file.byteSize == nil)
  }

  private func makeStore() throws -> VaultContentStore {
    try VaultContentStore.open(
      vaultID: VaultID(),
      layout: VaultStoreLayout(
        rootDirectoryURL: FileManager.default.temporaryDirectory.appending(
          path: "TinycurveSavedEntryContentTests-\(UUID().uuidString)",
          directoryHint: .isDirectory
        )
      )
    )
  }

  private func resource(
    attachmentID: UUID,
    role: JournalVault.AttachmentResource.Role,
    byteSize: Int = 0,
    contentType: String? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    duration: Double? = nil,
    waveformData: Data? = nil,
    localFileRevision: Int = 0
  ) -> JournalVault.AttachmentResource {
    JournalVault.AttachmentResource(
      attachmentID: attachmentID,
      role: role,
      byteSize: byteSize,
      contentType: contentType,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      duration: duration,
      waveformData: waveformData,
      localFileRevision: localFileRevision
    )
  }

  private func attach(
    to card: JournalVault.Card,
    id: UUID,
    kind: JournalVault.Attachment.Kind,
    primaryResource: JournalVault.AttachmentResource,
    resources: [JournalVault.AttachmentResource]? = nil
  ) {
    let attachment = JournalVault.Attachment(
      id: id,
      cardID: card.id,
      kind: kind,
      byteSize: primaryResource.byteSize,
      primaryResourceID: primaryResource.id
    )
    attachment.resources = resources ?? [primaryResource]
    attachment.card = card
    for resource in attachment.resources {
      resource.attachment = attachment
    }
    card.attachments = [attachment]
  }
}
