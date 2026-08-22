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

  // MARK: - Sync diagnostics

  @Test
  func localSyncCounts_reportRowsPerRecordTypeAndOutboxDepth() throws {
    let store = try makeStore()
    try store.seedVaultInfo(title: "Trip")
    _ = try store.createPost(cards: [
      .init(kind: .text, text: "first"),
      .init(kind: .text, text: "second"),
    ])

    let counts = try store.localSyncCounts()
    let context = store.container.mainContext

    #expect(counts.records.count(of: .vaultInfo) == 1)
    #expect(counts.records.count(of: .card) == 2)
    #expect(counts.records.count(of: .cardEdge) == 2)
    #expect(counts.records.count(of: .attachment) == 0)
    #expect(counts.records.otherRecordCount == 0)
    #expect(counts.records.total == 5 + counts.records.count(of: .activity))
    #expect(
      counts.pendingMutationCount == (try context.fetchCount(FetchDescriptor<PendingMutation>()))
    )
  }

  // MARK: - VaultInfo

  @Test
  func renameVault_updatesVaultInfoAndRearmsOutbox() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore {
      mutationCount.withLock { $0 += 1 }
    }
    try store.seedVaultInfo(title: "Old")

    let context = store.container.mainContext
    let originalInfo = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    let originalUpdatedAt = originalInfo.updatedAt

    let didRename = try store.renameVault(title: "New")

    let info = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    #expect(didRename)
    #expect(info.title == "New")
    #expect(info.updatedAt >= originalUpdatedAt)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 1)
    #expect(outbox.first?.recordType == VaultRecordType.vaultInfo.rawValue)
    #expect(outbox.first?.recordName == store.vaultID.uuidString)
    #expect(outbox.first?.kind == .save)
    #expect(mutationCount.withLock { $0 } == 2)
  }

  @Test
  func updateVaultIcon_updatesVaultInfoAndRearmsOutbox() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore {
      mutationCount.withLock { $0 += 1 }
    }
    try store.seedVaultInfo(title: "Trip")

    let context = store.container.mainContext
    let originalInfo = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    let originalUpdatedAt = originalInfo.updatedAt
    let icon = VaultIcon.emoji("\u{1F5FE}")

    let didUpdate = try store.updateVaultIcon(icon, title: "Trip")

    let info = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    #expect(didUpdate)
    #expect(info.icon == icon)
    #expect(info.updatedAt >= originalUpdatedAt)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 1)
    #expect(outbox.first?.recordType == VaultRecordType.vaultInfo.rawValue)
    #expect(outbox.first?.recordName == store.vaultID.uuidString)
    #expect(outbox.first?.kind == .save)
    #expect(mutationCount.withLock { $0 } == 2)
  }

  // MARK: - createPost

  @Test
  func createPost_singleDraft_createsRootEdgeAndEnqueuesOutbox() throws {
    let store = try makeStore()

    let edges = try store.createPost(cards: [.init(kind: .text, text: "hello")])

    let root = try #require(edges.first)
    #expect(edges.count == 1)
    #expect(root.parentEdgeID == nil)
    #expect(root.sortIndex == 0)

    let context = store.container.mainContext
    let cards = try context.fetch(FetchDescriptor<Card>())
    #expect(cards.count == 1)
    #expect(cards.first?.body == "hello")
    #expect(cards.first?.id == root.cardID)

    // The write and its pending uploads are one transaction: card + edge + Activity.
    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 3)
    #expect(outbox.allSatisfy { $0.kind == .save })
    #expect(
      Set(outbox.map(\.recordType))
        == [
          VaultRecordType.card.rawValue,
          VaultRecordType.cardEdge.rawValue,
          VaultActivity.recordType,
        ]
    )

    let activity = try #require(try context.fetch(FetchDescriptor<VaultActivity>()).first)
    #expect(activity.kind == .contentAdded)
    #expect(activity.recordName == activity.id.uuidString)
    #expect(activity.subjectEdgeID == root.id)
    #expect(activity.rootEdgeID == root.id)

    // The default test helper models a personal vault. History is retained,
    // while Shared with You intent and the participant-only Pulse stay absent.
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 0)
  }

  @Test
  func createPost_notifyParticipants_stagesActivityNoticeAndPulseTogether() throws {
    let store = try makeStore()

    let root = try #require(
      try store.createPost(
        cards: [.init(kind: .text, text: "hello participants")],
        deliveryPolicy: .notifyParticipants
      ).first
    )

    let context = store.container.mainContext
    let activity = try #require(try context.fetch(FetchDescriptor<VaultActivity>()).first)
    let notice = try #require(
      try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first
    )
    let pulse = try #require(
      try context.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())

    #expect(activity.subjectEdgeID == root.id)
    #expect(notice.activityID == activity.id)
    #expect(notice.state == .waitingForActivityUpload)
    #expect(pulse.recordName == VaultNotificationPulse.fixedRecordName)
    #expect(pulse.latestActivityRecordName == activity.recordName)
    #expect(pulse.kindRawValue == activity.kindRawValue)
    #expect(
      Set(outbox.map(\.recordType))
        == [
          VaultRecordType.card.rawValue,
          VaultRecordType.cardEdge.rawValue,
          VaultRecordType.activity.rawValue,
          VaultRecordType.notificationPulse.rawValue,
        ]
    )
  }

  @Test
  func createPost_notifyParticipants_rearmsSingletonPulse() throws {
    let store = try makeStore()
    _ = try store.createPost(
      cards: [.init(kind: .text, text: "first")],
      deliveryPolicy: .notifyParticipants
    )

    let context = store.container.mainContext
    let pendingPulse = try #require(
      try context.fetch(FetchDescriptor<PendingMutation>()).first {
        $0.recordName == VaultNotificationPulse.fixedRecordName
      }
    )
    // Model an already handed-off upload. A second authored action must clear
    // this marker rather than leave the singleton Pulse stranded in flight.
    pendingPulse.stagedAt = Date()
    try context.save()

    _ = try store.createPost(
      cards: [.init(kind: .text, text: "second")],
      deliveryPolicy: .notifyParticipants
    )

    let activities = try context.fetch(FetchDescriptor<VaultActivity>())
      .sorted { $0.createdAt < $1.createdAt }
    let pulse = try #require(
      try context.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    let rearmedPendingPulse = try #require(
      try context.fetch(FetchDescriptor<PendingMutation>()).first {
        $0.recordName == VaultNotificationPulse.fixedRecordName
      }
    )

    #expect(activities.count == 2)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 1)
    #expect(pulse.latestActivityRecordName == activities.last?.recordName)
    #expect(rearmedPendingPulse.recordType == VaultRecordType.notificationPulse.rawValue)
    #expect(rearmedPendingPulse.kind == .save)
    #expect(rearmedPendingPulse.stagedAt == nil)
  }

  @Test
  func createPost_notifyParticipants_twoOpenContainersReuseThePulse() throws {
    let vaultID = VaultID()
    let layout = makeTemporaryLayout()
    let firstStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    let secondStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )

    // Keep a second ModelContainer alive before the first author writes. This
    // models app and extension processes that opened the same vault earlier.
    #expect(
      try secondStore.container.mainContext.fetchCount(
        FetchDescriptor<VaultNotificationPulse>()
      ) == 0
    )
    _ = try firstStore.createPost(
      cards: [.init(kind: .text, text: "from app")],
      deliveryPolicy: .notifyParticipants
    )
    _ = try secondStore.createPost(
      cards: [.init(kind: .text, text: "from extension")],
      deliveryPolicy: .notifyParticipants
    )

    let verificationStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    let verificationContext = verificationStore.container.mainContext
    #expect(try verificationContext.fetchCount(FetchDescriptor<VaultActivity>()) == 2)
    #expect(try verificationContext.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 1)
    #expect(
      try verificationContext.fetch(FetchDescriptor<PendingMutation>())
        .filter { $0.recordName == VaultNotificationPulse.fixedRecordName }
        .count == 1
    )
  }

  @Test
  func pendingSharedWithYouNotice_skippedIsTerminalState() {
    let notice = PendingSharedWithYouNotice(activityID: UUID(), state: .skipped)

    #expect(notice.state == .skipped)
    #expect(notice.stateRawValue == "skipped")
  }

  @Test
  func createPost_todoStoresBodyAndDefaultsToIncomplete() throws {
    let store = try makeStore()

    let root = try #require(
      try store.createPost(cards: [
        .init(kind: .todo, text: "Book the train")
      ]).first
    )

    let context = store.container.mainContext
    let card = try #require(
      try context.fetch(FetchDescriptor<Card>()).first { $0.id == root.cardID }
    )
    #expect(card.kind == .todo)
    #expect(card.body == "Book the train")
    #expect(card.completedAt == nil)
    #expect(card.isCompleted == false)
    #expect(card.attachments.isEmpty)
  }

  @Test
  func createPost_multipleDrafts_buildsRootWithOrderedChildren() throws {
    let store = try makeStore()

    let edges = try store.createPost(cards: [
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

    let context = store.container.mainContext
    let activities = try context.fetch(FetchDescriptor<VaultActivity>())
    #expect(activities.count == 1)
    #expect(activities.first?.subjectEdgeID == root.id)
    #expect(activities.first?.rootEdgeID == root.id)
  }

  // MARK: - appendCard

  @Test
  func appendCard_buildsOrderedChildrenAndSupportsEveryDepth() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createPost(cards: [.init(kind: .text, text: "root")]).first
    )

    let firstChild = try store.appendCard(
      .init(kind: .text, text: "first child"),
      to: root.id
    )
    let secondChild = try store.appendCard(
      .init(kind: .text, text: "second child"),
      to: root.id
    )
    let grandchild = try store.appendCard(
      .init(kind: .text, text: "grandchild"),
      to: firstChild.id
    )

    #expect(firstChild.parentEdgeID == root.id)
    #expect(firstChild.sortIndex == 0)
    #expect(secondChild.parentEdgeID == root.id)
    #expect(secondChild.sortIndex == 1)
    #expect(grandchild.parentEdgeID == firstChild.id)
    #expect(grandchild.sortIndex == 0)

    let context = store.container.mainContext
    let cards = try context.fetch(FetchDescriptor<Card>())
    #expect(cards.count == 4)
    #expect(cards.first(where: { $0.id == grandchild.cardID })?.body == "grandchild")

    // Every authored action contributes card + edge + immutable Activity saves.
    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 12)

    let grandchildActivity = try #require(
      try context.fetch(FetchDescriptor<VaultActivity>()).first {
        $0.subjectEdgeID == grandchild.id
      }
    )
    #expect(grandchildActivity.rootEdgeID == root.id)
  }

  @Test
  func appendCard_missingParent_rollsBackWithoutRows() throws {
    let store = try makeStore()
    let missingParentID = UUID()

    #expect(throws: VaultContentStore.Error.self) {
      try store.appendCard(
        .init(kind: .text, text: "orphan"),
        to: missingParentID
      )
    }

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
  }

  @Test
  func appendCard_mediaDraft_writesAttachmentAndResource() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createPost(cards: [.init(kind: .text, text: "root")]).first
    )
    let bytes = Data([0xFF, 0x01, 0x02, 0x03])

    let child = try store.appendCard(
      .init(kind: .photo, mediaData: bytes),
      to: root.id
    )

    let context = store.container.mainContext
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    #expect(child.parentEdgeID == root.id)
    #expect(attachment.cardID == child.cardID)
    #expect(resource.attachmentID == attachment.id)
    #expect(try Data(contentsOf: store.fileURL(for: resource)) == bytes)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 8)
  }

  @Test
  func createPost_audioDraftPersistsWaveformBesideAudioResource() throws {
    let store = try makeStore()
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("waveform-audio-\(UUID().uuidString)")
      .appendingPathExtension("m4a")
    let audioBytes = Data([0x00, 0x01, 0x02])
    let waveformData = Data(#"{"formatVersion":1}"#.utf8)
    try audioBytes.write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    try store.createPost(cards: [
      .init(
        kind: .audio,
        mediaResources: [
          .init(
            role: .audio,
            fileURL: sourceURL,
            contentType: "public.mpeg-4-audio",
            duration: 2.5,
            waveformData: waveformData
          )
        ]
      )
    ])

    let resource = try #require(
      try store.container.mainContext.fetch(
        FetchDescriptor<JournalVault.AttachmentResource>()
      ).first
    )
    #expect(resource.role == .audio)
    #expect(resource.duration == 2.5)
    #expect(resource.waveformData == waveformData)
    #expect(try Data(contentsOf: store.fileURL(for: resource)) == audioBytes)

    let estimate = try store.cloudStorageEstimate()
    #expect(estimate.waveformBytes == waveformData.count)
    #expect(estimate.inlinePayloadBytes == waveformData.count)
    #expect(estimate.estimatedPayloadBytes == waveformData.count + audioBytes.count)
  }

  @Test
  func latestRootCard_ignoresNewerContinuations() throws {
    let store = try makeStore()
    _ = try store.createPost(cards: [.init(kind: .text, text: "older root")])
    let newestRoot = try #require(
      try store.createPost(cards: [.init(kind: .text, text: "newest root")]).first
    )
    let olderRoot = try #require(
      try store.container.mainContext.fetch(FetchDescriptor<CardEdge>())
        .first(where: { $0.parentEdgeID == nil && $0.id != newestRoot.id })
    )
    olderRoot.createdAt = .distantPast
    newestRoot.createdAt = .now
    try store.container.mainContext.save()
    _ = try store.appendCard(
      .init(kind: .text, text: "newest authored child"),
      to: olderRoot.id
    )

    let latestRoot = try #require(try store.latestRootCard())

    #expect(latestRoot.id == newestRoot.cardID)
    #expect(latestRoot.body == "newest root")
  }

  @Test
  func createPost_mediaDraft_writesFileAndAttachmentRow() throws {
    let store = try makeStore()
    let bytes = Data([0xFF, 0x01, 0x02, 0x03])

    try store.createPost(cards: [
      .init(kind: .photo, mediaData: bytes)
    ])

    let context = store.container.mainContext
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    #expect(attachment.kind == .photo)
    #expect(attachment.byteSize == bytes.count)

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
    #expect(outbox.count == 5)  // card + edge + attachment + resource + Activity
    #expect(outbox.contains { $0.recordType == VaultRecordType.attachment.rawValue })
    #expect(outbox.contains { $0.recordType == VaultRecordType.attachmentResource.rawValue })
  }

  @Test
  func createPost_livePhotoDraft_writesStillAndPairedVideoResources() throws {
    let store = try makeStore()
    let stillBytes = Data([0x01, 0x02, 0x03])
    let pairedVideoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("paired-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let pairedVideoBytes = Data([0x10, 0x11, 0x12, 0x13])
    try pairedVideoBytes.write(to: pairedVideoURL)

    try store.createPost(cards: [
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
        ]
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
    #expect(outbox.count == 6)  // card + edge + attachment + 2 resources + Activity
    #expect(
      outbox.filter { $0.recordType == VaultRecordType.attachmentResource.rawValue }.count == 2)
  }

  @Test
  func createPost_fileStagingFailure_rollsBackAndCanRetry() throws {
    let store = try makeStore()
    let stillURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-still-\(UUID().uuidString)")
      .appendingPathExtension("heic")
    let pairedVideoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-paired-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let stillBytes = Data([0x21, 0x22, 0x23])
    let pairedVideoBytes = Data([0x31, 0x32, 0x33])
    try stillBytes.write(to: stillURL)

    let draft = VaultContentStore.CardDraft(
      kind: .livePhoto,
      mediaResources: [
        .init(role: .stillImage, fileURL: stillURL),
        .init(role: .pairedVideo, fileURL: pairedVideoURL),
      ]
    )

    var didFail = false
    do {
      try store.createPost(cards: [draft])
    } catch {
      didFail = true
    }

    #expect(didFail)
    #expect(FileManager.default.fileExists(atPath: stillURL.path))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: store.mediaDirectoryURL,
        includingPropertiesForKeys: nil
      ).isEmpty
    )

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)

    try pairedVideoBytes.write(to: pairedVideoURL)
    try store.createPost(cards: [draft])

    #expect(FileManager.default.fileExists(atPath: stillURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: pairedVideoURL.path) == false)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 6)
  }

  @Test
  func createPost_copyResource_preservesSourceAfterCommit() throws {
    let store = try makeStore()
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("copy-source-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let bytes = Data([0x41, 0x42, 0x43])
    try bytes.write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    try store.createPost(cards: [
      .init(
        kind: .video,
        mediaResources: [
          .init(
            role: .originalVideo,
            fileURL: sourceURL,
            fileTransferMode: .copy
          )
        ]
      )
    ])

    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    let resource = try #require(
      try store.container.mainContext.fetch(
        FetchDescriptor<JournalVault.AttachmentResource>()
      ).first
    )
    #expect(try Data(contentsOf: store.fileURL(for: resource)) == bytes)
  }

  @Test
  func updateCard_fileStagingFailure_restoresSavedCardAndMedia() throws {
    let store = try makeStore()
    let originalBytes = Data([0x51, 0x52, 0x53])
    let root = try #require(
      try store.createPost(cards: [
        .init(kind: .photo, mediaData: originalBytes)
      ]).first
    )
    let context = store.container.mainContext
    let originalResource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let originalResourceID = originalResource.id
    let originalFileURL = store.fileURL(for: originalResource)

    let stillURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("update-still-\(UUID().uuidString)")
      .appendingPathExtension("heic")
    let pairedVideoURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("update-paired-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    try Data([0x61, 0x62]).write(to: stillURL)
    try Data([0x71, 0x72]).write(to: pairedVideoURL)
    defer { try? FileManager.default.removeItem(at: stillURL) }
    defer { try? FileManager.default.removeItem(at: pairedVideoURL) }

    // Both inputs pass preflight validation. Reusing one resource id makes the
    // second staged destination collide after the old attachment and card have
    // already been mutated, exercising the transactional rollback path.
    let collidingResourceID = UUID()

    var didFail = false
    do {
      try store.updateCard(
        cardID: root.cardID,
        with: .init(
          kind: .livePhoto,
          mediaResources: [
            .init(id: collidingResourceID, role: .stillImage, fileURL: stillURL),
            .init(id: collidingResourceID, role: .pairedVideo, fileURL: pairedVideoURL),
          ]
        )
      )
    } catch {
      didFail = true
    }

    #expect(didFail)
    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    let resources = try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>())
    #expect(card.kind == .photo)
    #expect(resources.count == 1)
    #expect(resources.first?.id == originalResourceID)
    #expect(try Data(contentsOf: originalFileURL) == originalBytes)
    #expect(FileManager.default.fileExists(atPath: stillURL.path))
    #expect(FileManager.default.fileExists(atPath: pairedVideoURL.path))
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 5)
  }

  @Test
  func createPost_linkDraft_storesURLWithoutAttachment() throws {
    let store = try makeStore()

    try store.createPost(cards: [
      .init(kind: .link, text: "https://example.com/article")
    ])

    let context = store.container.mainContext
    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    #expect(card.kind == .link)
    #expect(card.body == "https://example.com/article")
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 3)  // card + edge + Activity
    #expect(
      Set(outbox.map(\.recordType))
        == [
          VaultRecordType.card.rawValue,
          VaultRecordType.cardEdge.rawValue,
          VaultActivity.recordType,
        ]
    )
  }

  @Test
  func createPost_fileDraft_storesDisplayNameAndOriginalFile() throws {
    let store = try makeStore()
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("trip-itinerary-\(UUID().uuidString)")
      .appendingPathExtension("pdf")
    let bytes = Data([0x25, 0x50, 0x44, 0x46])
    try bytes.write(to: sourceURL)
    defer { try? FileManager.default.removeItem(at: sourceURL) }

    try store.createPost(cards: [
      .init(
        kind: .file,
        text: "Trip Itinerary.pdf",
        mediaResources: [
          .init(
            role: .file,
            fileURL: sourceURL,
            contentType: "com.adobe.pdf"
          )
        ]
      )
    ])

    let context = store.container.mainContext
    let card = try #require(try context.fetch(FetchDescriptor<Card>()).first)
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )

    #expect(card.kind == .file)
    #expect(card.body == "Trip Itinerary.pdf")
    #expect(attachment.kind == .file)
    #expect(attachment.primaryResourceID == resource.id)
    #expect(attachment.byteSize == bytes.count)
    #expect(resource.role == .file)
    #expect(resource.byteSize == bytes.count)
    #expect(resource.contentType == "com.adobe.pdf")
    #expect(store.fileURL(for: resource).pathExtension == "pdf")
    #expect(try Data(contentsOf: store.fileURL(for: resource)) == bytes)
    #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 5)  // card + edge + attachment + resource + Activity
  }

  @Test
  func createPost_missingFilePayload_rejectsEntirePostBeforeWriting() throws {
    let store = try makeStore()

    do {
      try store.createPost(cards: [
        .init(kind: .text, text: "This must not be saved"),
        .init(kind: .file, text: "Missing.pdf"),
      ])
      Issue.record("Expected the file draft without bytes to be rejected")
    } catch let error as VaultContentStore.Error {
      switch error {
      case .missingMediaPayload(let kind):
        #expect(kind == .file)
      case .cardNotFound, .cardEdgeNotFound, .invalidCardEdgeTopology, .cardIsNotTodo:
        Issue.record("Expected missingMediaPayload, received \(error)")
      }
    }

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
  }

  @Test
  func cloudStorageEstimate_countsRowsBodyAndMedia() throws {
    let store = try makeStore()
    try store.seedVaultInfo(title: "Personal")

    let photoBytes = Data([0x01, 0x02, 0x03, 0x04])
    try store.createPost(cards: [
      .init(kind: .text, text: "hello"),
      .init(kind: .link, text: "https://example.com/article"),
      .init(kind: .photo, mediaData: photoBytes),
    ])

    let estimate = try store.cloudStorageEstimate()

    #expect(estimate.vaultInfoCount == 1)
    #expect(estimate.cardCount == 3)
    #expect(estimate.cardEdgeCount == 3)
    #expect(estimate.attachmentCount == 1)
    #expect(estimate.attachmentResourceCount == 1)
    #expect(estimate.activityCount == 1)
    #expect(estimate.notificationPulseCount == 0)
    #expect(estimate.recordCount == 10)
    #expect(
      estimate.cardBodyBytes
        == "hello".utf8.count + "https://example.com/article".utf8.count
    )
    #expect(estimate.mediaBytes == photoBytes.count)
    #expect(
      estimate.inlinePayloadBytes
        == estimate.cardBodyBytes + estimate.waveformBytes
    )
    #expect(estimate.estimatedPayloadBytes == estimate.inlinePayloadBytes + photoBytes.count)

    let photoBreakdown = try #require(estimate.mediaBreakdowns.first { $0.kind == .photo })
    #expect(photoBreakdown.count == 1)
    #expect(photoBreakdown.byteSize == photoBytes.count)
  }

  // MARK: - updateCardBody

  @Test
  func setTodoCompletion_completesReopensAndReusesCardOutbox() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore {
      mutationCount.withLock { $0 += 1 }
    }
    let root = try #require(
      try store.createPost(cards: [
        .init(kind: .todo, text: "Pick up flowers")
      ]).first
    )
    let context = store.container.mainContext
    let card = try #require(
      try context.fetch(FetchDescriptor<Card>()).first { $0.id == root.cardID }
    )
    let initialUpdatedAt = card.updatedAt

    let didComplete = try store.setTodoCompletion(
      cardID: root.cardID,
      isCompleted: true
    )

    #expect(didComplete)
    #expect(card.completedAt != nil)
    #expect(card.isCompleted)
    #expect(card.updatedAt >= initialUpdatedAt)
    #expect(mutationCount.withLock { $0 } == 2)

    let unchangedCompletionDate = card.completedAt
    let didRepeatCompletion = try store.setTodoCompletion(
      cardID: root.cardID,
      isCompleted: true
    )
    #expect(didRepeatCompletion == false)
    #expect(card.completedAt == unchangedCompletionDate)
    #expect(mutationCount.withLock { $0 } == 2)

    let didReopen = try store.setTodoCompletion(
      cardID: root.cardID,
      isCompleted: false
    )
    #expect(didReopen)
    #expect(card.completedAt == nil)
    #expect(card.isCompleted == false)
    #expect(mutationCount.withLock { $0 } == 3)

    let cardMutations = try context.fetch(FetchDescriptor<PendingMutation>())
      .filter { $0.recordName == root.cardID.uuidString }
    #expect(cardMutations.count == 1)
    #expect(cardMutations.first?.kind == .save)
  }

  @Test
  func updateCard_todoBodyPreservesCompletionTimestamp() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createPost(cards: [
        .init(kind: .todo, text: "Draft")
      ]).first
    )
    _ = try store.setTodoCompletion(cardID: root.cardID, isCompleted: true)

    let context = store.container.mainContext
    let card = try #require(
      try context.fetch(FetchDescriptor<Card>()).first { $0.id == root.cardID }
    )
    let completedAt = try #require(card.completedAt)

    try store.updateCard(
      cardID: root.cardID,
      with: .init(
        kind: .todo,
        text: "Final wording",
        completedAt: completedAt
      )
    )

    #expect(card.kind == .todo)
    #expect(card.body == "Final wording")
    #expect(card.completedAt == completedAt)
    #expect(card.isCompleted)
  }

  @Test
  func setTodoCompletion_rejectsNonTodoCard() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createPost(cards: [.init(kind: .text, text: "Note")]).first
    )

    #expect(throws: VaultContentStore.Error.self) {
      try store.setTodoCompletion(cardID: root.cardID, isCompleted: true)
    }
  }

  @Test
  func updateCardBody_reArmsExistingOutboxRowWithoutDuplicating() throws {
    let store = try makeStore()
    let root = try #require(try store.createPost(cards: [.init(kind: .text, text: "v1")]).first)

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
      try store.createPost(cards: [
        .init(kind: .photo, mediaData: Data([0x01, 0x02]))
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
        mediaData: Data([0x03, 0x04, 0x05])
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
      try store.createPost(cards: [
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
  func deleteCardEdge_neverSynced_retainsRowsAndDropsUnneededOutbox() throws {
    let store = try makeStore()
    let root = try #require(
      try store.createPost(cards: [
        .init(kind: .text, text: "a"),
        .init(kind: .text, text: "b"),
      ]).first
    )

    try store.deleteCardEdge(edgeID: root.id)

    let context = store.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 2)
    let edges = try context.fetch(FetchDescriptor<CardEdge>())
    #expect(edges.count == 2)
    #expect(edges.allSatisfy { $0.deletedAt != nil })
    #expect(Set(edges.compactMap(\.deletedAt)).count == 1)
    // Content never reached CloudKit, so no remote tombstones are needed.
    // The durable Activity is intentionally retained and still awaits upload.
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 1)
  }

  @Test
  func deleteCardEdge_syncedRows_enqueuesDeleteTombstones() throws {
    let store = try makeStore()
    let root = try #require(try store.createPost(cards: [.init(kind: .text, text: "a")]).first)

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
    #expect(root.deletedAt != nil)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 1)
  }

  @Test
  func deleteCardEdge_retainsSubtreeAndMediaFiles() throws {
    let store = try makeStore()
    let edges = try store.createPost(cards: [
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

    let retainedEdges = try context.fetch(FetchDescriptor<CardEdge>())
    #expect(retainedEdges.count == 2)
    #expect(retainedEdges.allSatisfy { $0.deletedAt != nil })
    #expect(Set(retainedEdges.compactMap(\.deletedAt)).count == 1)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 1)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try store.latestRootCard() == nil)

    let cloudEstimate = try store.cloudStorageEstimate()
    #expect(cloudEstimate.cardEdgeCount == 0)
    #expect(cloudEstimate.cardCount == 0)
    #expect(cloudEstimate.attachmentCount == 0)
    #expect(cloudEstimate.attachmentResourceCount == 0)
    #expect(cloudEstimate.mediaBytes == 0)
  }

  // MARK: - Local mutation signal

  @Test
  func writes_fireLocalMutationSignal() throws {
    let mutationCount = Mutex(0)
    let store = try makeStore(onLocalMutation: { mutationCount.withLock { $0 += 1 } })

    let root = try #require(try store.createPost(cards: [.init(kind: .text, text: "a")]).first)
    #expect(mutationCount.withLock { $0 } == 1)

    let child = try store.appendCard(.init(kind: .text, text: "child"), to: root.id)
    #expect(mutationCount.withLock { $0 } == 2)

    try store.updateCardBody(cardID: root.cardID, body: "b")
    #expect(mutationCount.withLock { $0 } == 3)

    try store.deleteCardEdge(edgeID: child.id)
    #expect(mutationCount.withLock { $0 } == 4)
  }
}
