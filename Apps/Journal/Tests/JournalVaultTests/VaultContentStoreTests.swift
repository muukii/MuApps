import Foundation
import SwiftData
import Synchronization
import Testing

@testable import JournalVault

@MainActor
struct VaultContentStoreTests {

  private func makeStore(
    onLocalMutation: @escaping @Sendable () -> Void = {}
  ) throws -> VaultContentStore {
    try VaultContentStore.open(
      vaultID: VaultID(),
      layout: makeTemporaryLayout(),
      onLocalMutation: onLocalMutation
    )
  }

  // MARK: - createThread

  @Test
  func createThread_singleDraft_createsRootEdgeAndEnqueuesOutbox() throws {
    let store = try makeStore()

    let edges = try store.createThread(cards: [.init(kind: .text, text: "hello")])

    let root = try #require(edges.first)
    #expect(edges.count == 1)
    #expect(root.parentEdgeID == nil)
    #expect(root.sortIndex == 0)

    let context = store.container.mainContext
    let cards = try context.fetch(FetchDescriptor<Card>())
    #expect(cards.count == 1)
    #expect(cards.first?.body == "hello")
    #expect(cards.first?.id == root.cardID)

    // The write and its pending uploads are one transaction: card + edge.
    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 2)
    #expect(outbox.allSatisfy { $0.kind == .save })
    #expect(
      Set(outbox.map(\.recordType))
        == [VaultRecordType.card.rawValue, VaultRecordType.cardEdge.rawValue]
    )
  }

  @Test
  func createThread_multipleDrafts_buildsRootWithOrderedChildren() throws {
    let store = try makeStore()

    let edges = try store.createThread(cards: [
      .init(kind: .text, text: "first"),
      .init(kind: .text, text: "second"),
      .init(kind: .text, text: "third"),
    ])

    #expect(edges.count == 3)
    let root = edges[0]
    #expect(root.parentEdgeID == nil)
    #expect(edges[1].parentEdgeID == root.id)
    #expect(edges[1].sortIndex == 0)
    #expect(edges[2].parentEdgeID == root.id)
    #expect(edges[2].sortIndex == 1)

    // Authored order also holds for date-sorted readers.
    #expect(edges[0].createdAt < edges[1].createdAt)
    #expect(edges[1].createdAt < edges[2].createdAt)
  }

  @Test
  func createThread_mediaDraft_writesFileAndAttachmentRow() throws {
    let store = try makeStore()
    let bytes = Data([0xFF, 0x01, 0x02, 0x03])

    try store.createThread(cards: [
      .init(kind: .photo, mediaData: bytes, thumbnail: Data([0x00]))
    ])

    let context = store.container.mainContext
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    #expect(attachment.kind == .photo)
    #expect(attachment.byteSize == bytes.count)
    #expect(attachment.thumbnail == Data([0x00]))

    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    #expect(resource.attachmentID == attachment.id)
    #expect(resource.role == .originalImage)
    #expect(resource.byteSize == bytes.count)
    #expect(resource.contentType == "public.jpeg")
    #expect(attachment.primaryResourceID == resource.id)

    let fileURL = store.fileURL(for: resource)
    #expect(try Data(contentsOf: fileURL) == bytes)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 4)  // card + edge + attachment + resource
    #expect(outbox.contains { $0.recordType == VaultRecordType.attachment.rawValue })
    #expect(outbox.contains { $0.recordType == VaultRecordType.attachmentResource.rawValue })
  }

  @Test
  func createThread_livePhotoDraft_writesStillAndPairedVideoResources() throws {
    let store = try makeStore()
    let stillBytes = Data([0x01, 0x02, 0x03])
    let pairedVideoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("paired-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let pairedVideoBytes = Data([0x10, 0x11, 0x12, 0x13])
    try pairedVideoBytes.write(to: pairedVideoURL)

    try store.createThread(cards: [
      .init(
        kind: .livePhoto,
        mediaResources: [
          .init(
            role: .stillImage,
            data: stillBytes,
            contentType: "public.heic",
            pixelWidth: 4032,
            pixelHeight: 3024
          ),
          .init(
            role: .pairedVideo,
            fileURL: pairedVideoURL,
            contentType: "com.apple.quicktime-movie",
            pixelWidth: 4032,
            pixelHeight: 3024,
            duration: 1.4
          ),
        ],
        thumbnail: Data([0xA0])
      )
    ])

    let context = store.container.mainContext
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resources = try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>())
      .sorted { $0.createdAt < $1.createdAt }
    let still = try #require(resources.first { $0.role == .stillImage })
    let pairedVideo = try #require(resources.first { $0.role == .pairedVideo })

    #expect(attachment.kind == .livePhoto)
    #expect(attachment.byteSize == stillBytes.count)
    #expect(attachment.primaryResourceID == still.id)
    #expect(attachment.thumbnail == Data([0xA0]))
    #expect(resources.count == 2)
    #expect(still.contentType == "public.heic")
    #expect(still.pixelWidth == 4032)
    #expect(still.pixelHeight == 3024)
    #expect(pairedVideo.contentType == "com.apple.quicktime-movie")
    #expect(pairedVideo.duration == 1.4)
    #expect(try Data(contentsOf: store.fileURL(for: still)) == stillBytes)
    #expect(try Data(contentsOf: store.fileURL(for: pairedVideo)) == pairedVideoBytes)
    #expect(FileManager.default.fileExists(atPath: pairedVideoURL.path) == false)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 5)  // card + edge + attachment + 2 resources
    #expect(outbox.filter { $0.recordType == VaultRecordType.attachmentResource.rawValue }.count == 2)
  }

  @Test
  func createThread_linkDraft_storesURLWithoutAttachment() throws {
    let store = try makeStore()

    try store.createThread(cards: [
      .init(kind: .link, text: "https://example.com/article")
    ])

    let context = store.container.mainContext
    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    #expect(card.kind == .link)
    #expect(card.body == "https://example.com/article")
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 2)  // card + edge
    #expect(
      Set(outbox.map(\.recordType))
        == [VaultRecordType.card.rawValue, VaultRecordType.cardEdge.rawValue]
    )
  }

  @Test
  func cloudStorageEstimate_countsRowsBodyMediaAndThumbnails() throws {
    let store = try makeStore()
    try store.seedVaultInfo(title: "Personal")

    let photoBytes = Data([0x01, 0x02, 0x03, 0x04])
    let thumbnailBytes = Data([0x10, 0x11])
    try store.createThread(cards: [
      .init(kind: .text, text: "hello"),
      .init(kind: .link, text: "https://example.com/article"),
      .init(kind: .photo, mediaData: photoBytes, thumbnail: thumbnailBytes),
    ])

    let estimate = try store.cloudStorageEstimate()

    #expect(estimate.vaultInfoCount == 1)
    #expect(estimate.cardCount == 3)
    #expect(estimate.cardEdgeCount == 3)
    #expect(estimate.attachmentCount == 1)
    #expect(estimate.attachmentResourceCount == 1)
    #expect(estimate.recordCount == 9)
    #expect(
      estimate.cardBodyBytes
        == "hello".utf8.count + "https://example.com/article".utf8.count
    )
    #expect(estimate.mediaBytes == photoBytes.count)
    #expect(estimate.thumbnailBytes == thumbnailBytes.count)
    #expect(estimate.inlinePayloadBytes == estimate.cardBodyBytes + thumbnailBytes.count)
    #expect(estimate.estimatedPayloadBytes == estimate.inlinePayloadBytes + photoBytes.count)

    let photoBreakdown = try #require(estimate.mediaBreakdowns.first { $0.kind == .photo })
    #expect(photoBreakdown.count == 1)
    #expect(photoBreakdown.byteSize == photoBytes.count)
  }

  // MARK: - updateCardBody

  @Test
  func updateCardBody_reArmsExistingOutboxRowWithoutDuplicating() throws {
    let store = try makeStore()
    let root = try #require(try store.createThread(cards: [.init(kind: .text, text: "v1")]).first)

    try store.updateCardBody(cardID: root.cardID, body: "v2")

    let context = store.container.mainContext
    let cards = try context.fetch(FetchDescriptor<Card>())
    #expect(cards.first?.body == "v2")

    let cardRecordName = root.cardID.uuidString
    let cardMutations = try context.fetch(FetchDescriptor<PendingMutation>())
      .filter { $0.recordName == cardRecordName }
    #expect(cardMutations.count == 1)
    #expect(cardMutations.first?.kind == .save)
  }

  @Test
  func updateCard_replacesMediaAttachmentAndRemovesOldFile() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createThread(cards: [
        .init(kind: .photo, mediaData: Data([0x01, 0x02]), thumbnail: Data([0x10]))
      ]).first
    )

    let context = store.container.mainContext
    let oldAttachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let oldResource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let oldAttachmentID = oldAttachment.id
    let oldResourceID = oldResource.id
    let oldFileURL = store.fileURL(for: oldResource)
    #expect(FileManager.default.fileExists(atPath: oldFileURL.path))

    try store.updateCard(
      cardID: root.cardID,
      with: .init(
        kind: .doodle,
        mediaData: Data([0x03, 0x04, 0x05]),
        thumbnail: Data([0x20])
      )
    )

    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    #expect(card.kind == .doodle)
    #expect(card.body == "")

    let attachments = try context.fetch(FetchDescriptor<JournalVault.Attachment>())
    let attachment = try #require(attachments.first)
    let resources = try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>())
    let resource = try #require(resources.first)
    #expect(attachments.count == 1)
    #expect(resources.count == 1)
    #expect(attachment.id != oldAttachmentID)
    #expect(resource.id != oldResourceID)
    #expect(resource.attachmentID == attachment.id)
    #expect(attachment.primaryResourceID == resource.id)
    #expect(attachment.kind == .doodle)
    #expect(attachment.byteSize == 3)
    #expect(resource.role == .authoredJSON)
    #expect(resource.byteSize == 3)
    #expect(attachment.thumbnail == Data([0x20]))
    #expect(try Data(contentsOf: store.fileURL(for: resource)) == Data([0x03, 0x04, 0x05]))
    #expect(FileManager.default.fileExists(atPath: oldFileURL.path) == false)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.contains { $0.recordName == root.cardID.uuidString && $0.kind == .save })
    #expect(outbox.contains { $0.recordName == attachment.id.uuidString && $0.kind == .save })
    #expect(outbox.contains { $0.recordName == resource.id.uuidString && $0.kind == .save })
    #expect(outbox.contains { $0.recordName == oldAttachmentID.uuidString } == false)
    #expect(outbox.contains { $0.recordName == oldResourceID.uuidString } == false)
  }

  @Test
  func updateCard_textReplacementRemovesMediaAttachment() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createThread(cards: [
        .init(kind: .photo, mediaData: Data([0x01, 0x02]))
      ]).first
    )

    let context = store.container.mainContext
    _ = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let oldResource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let oldFileURL = store.fileURL(for: oldResource)

    try store.updateCard(
      cardID: root.cardID,
      with: .init(kind: .text, text: "edited")
    )

    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    #expect(card.kind == .text)
    #expect(card.body == "edited")
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)
    #expect(FileManager.default.fileExists(atPath: oldFileURL.path) == false)
  }

  // MARK: - deleteCardEdge

  @Test
  func deleteCardEdge_neverSynced_dropsOutboxWithoutTombstones() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createThread(cards: [
        .init(kind: .text, text: "a"),
        .init(kind: .text, text: "b"),
      ]).first
    )

    try store.deleteCardEdge(edgeID: root.id)

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    // Nothing ever reached CloudKit, so no remote tombstones are needed.
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
  }

  @Test
  func deleteCardEdge_syncedRows_enqueuesDeleteTombstones() throws {
    let store = try makeStore()
    let root = try #require(try store.createThread(cards: [.init(kind: .text, text: "a")]).first)

    // Simulate a completed upload: server metadata exists, outbox is drained.
    let context = store.container.mainContext
    for pending in try context.fetch(FetchDescriptor<PendingMutation>()) {
      context.insert(
        SyncMetadata(
          recordName: pending.recordName,
          recordType: pending.recordType,
          systemFieldsData: Data()
        )
      )
      context.delete(pending)
    }
    try context.save()

    try store.deleteCardEdge(edgeID: root.id)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 2)  // card + edge tombstones
    #expect(outbox.allSatisfy { $0.kind == .delete })
  }

  @Test
  func deleteCardEdge_removesSubtreeAndMediaFiles() throws {
    let store = try makeStore()
    let edges = try store.createThread(cards: [
      .init(kind: .text, text: "root"),
      .init(kind: .photo, mediaData: Data([0x01, 0x02])),
    ])
    let root = try #require(edges.first)

    let context = store.container.mainContext
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let fileURL = store.fileURL(for: resource)
    #expect(attachment.primaryResourceID == resource.id)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    try store.deleteCardEdge(edgeID: root.id)

    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)
    #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
  }

  // MARK: - Local mutation signal

  @Test
  func writes_fireLocalMutationSignal() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore(onLocalMutation: { mutationCount.withLock { $0 += 1 } })

    let root = try #require(try store.createThread(cards: [.init(kind: .text, text: "a")]).first)
    #expect(mutationCount.withLock { $0 } == 1)

    try store.updateCardBody(cardID: root.cardID, body: "b")
    #expect(mutationCount.withLock { $0 } == 2)

    try store.deleteCardEdge(edgeID: root.id)
    #expect(mutationCount.withLock { $0 } == 3)
  }
}
