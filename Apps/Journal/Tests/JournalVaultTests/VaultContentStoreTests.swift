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

    let fileURL = store.fileURL(for: attachment)
    #expect(try Data(contentsOf: fileURL) == bytes)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 3)  // card + edge + attachment
    #expect(outbox.contains { $0.recordType == VaultRecordType.attachment.rawValue })
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

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 2)  // card + edge
    #expect(
      Set(outbox.map(\.recordType))
        == [VaultRecordType.card.rawValue, VaultRecordType.cardEdge.rawValue]
    )
  }

  // MARK: - migration import

  @Test
  func importMigratedContent_insertsRowsCopiesMediaAndQueuesOutbox() throws {
    let store = try makeStore()
    let cardID = UUID()
    let edgeID = UUID()
    let attachmentID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let sourceFileURL = FileManager.default.temporaryDirectory.appending(
      path: "JournalVaultImport-\(UUID().uuidString)",
      directoryHint: .notDirectory
    )
    let mediaBytes = Data([0xCA, 0xFE, 0x01])
    try mediaBytes.write(to: sourceFileURL)

    let result = try store.importMigratedContent(
      cards: [
        .init(
          id: cardID,
          kind: .photo,
          body: "",
          createdAt: createdAt,
          updatedAt: createdAt,
          location: Coordinate(latitude: 35.0, longitude: 139.0)
        )
      ],
      edges: [
        .init(
          id: edgeID,
          cardID: cardID,
          createdAt: createdAt,
          updatedAt: createdAt
        )
      ],
      attachments: [
        .init(
          id: attachmentID,
          cardID: cardID,
          kind: .photo,
          byteSize: mediaBytes.count,
          thumbnail: Data([0x00]),
          createdAt: createdAt,
          sourceFileURL: sourceFileURL
        )
      ]
    )

    #expect(result.insertedCards == 1)
    #expect(result.insertedEdges == 1)
    #expect(result.insertedAttachments == 1)
    #expect(result.copiedMediaFiles == 1)

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 1)
    #expect(try Data(contentsOf: store.fileURL(forAttachmentID: attachmentID)) == mediaBytes)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 3)
    #expect(
      Set(outbox.map(\.recordType))
        == [
          VaultRecordType.card.rawValue,
          VaultRecordType.cardEdge.rawValue,
          VaultRecordType.attachment.rawValue,
        ]
    )
  }

  @Test
  func importMigratedContent_isIdempotentWhenRowsAreUnchanged() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore(onLocalMutation: { mutationCount.withLock { $0 += 1 } })
    let cardID = UUID()
    let edgeID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let cards = [
      VaultContentStore.MigratedCard(
        id: cardID,
        kind: .text,
        body: "legacy",
        createdAt: createdAt,
        updatedAt: createdAt
      )
    ]
    let edges = [
      VaultContentStore.MigratedCardEdge(
        id: edgeID,
        cardID: cardID,
        createdAt: createdAt,
        updatedAt: createdAt
      )
    ]

    let first = try store.importMigratedContent(
      cards: cards,
      edges: edges,
      attachments: []
    )
    let second = try store.importMigratedContent(
      cards: cards,
      edges: edges,
      attachments: []
    )

    #expect(first.didChange)
    #expect(second.didChange == false)
    #expect(mutationCount.withLock { $0 } == 1)

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 2)
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
    let oldAttachmentID = oldAttachment.id
    let oldFileURL = store.fileURL(for: oldAttachment)
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
    #expect(attachments.count == 1)
    #expect(attachment.id != oldAttachmentID)
    #expect(attachment.kind == .doodle)
    #expect(attachment.byteSize == 3)
    #expect(attachment.thumbnail == Data([0x20]))
    #expect(try Data(contentsOf: store.fileURL(for: attachment)) == Data([0x03, 0x04, 0x05]))
    #expect(FileManager.default.fileExists(atPath: oldFileURL.path) == false)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.contains { $0.recordName == root.cardID.uuidString && $0.kind == .save })
    #expect(outbox.contains { $0.recordName == attachment.id.uuidString && $0.kind == .save })
    #expect(outbox.contains { $0.recordName == oldAttachmentID.uuidString } == false)
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
    let oldAttachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let oldFileURL = store.fileURL(for: oldAttachment)

    try store.updateCard(
      cardID: root.cardID,
      with: .init(kind: .text, text: "edited")
    )

    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    #expect(card.kind == .text)
    #expect(card.body == "edited")
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
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
    let fileURL = store.fileURL(for: attachment)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    try store.deleteCardEdge(edgeID: root.id)

    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
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
