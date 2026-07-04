import Foundation
import SwiftData

/// One vault's content store: the local truth SwiftUI observes.
///
/// CloudKit mirroring is disabled by design — `VaultSyncEngine` owns CloudKit.
/// Every write here therefore does two things in one transaction: mutate the
/// content rows *and* enqueue matching `PendingMutation` outbox rows, so a
/// local change can never exist without its pending upload (and vice versa).
///
/// The write API is `@MainActor` and works on `container.mainContext` — the
/// same context SwiftUI observes. The sync engine reads and writes the store
/// through its own background `ModelActor` (`VaultSyncDatabase`), never through
/// this API, so imports don't ping-pong back into the outbox.
public struct VaultContentStore: Sendable {

  public static let schema = Schema([
    VaultInfo.self,
    Card.self,
    CardEdge.self,
    Attachment.self,
    SyncMetadata.self,
    PendingMutation.self,
  ])

  public let vaultID: VaultID

  public let container: ModelContainer

  /// Directory holding attachment bytes, inside the vault directory so media
  /// and rows share the same vault boundary.
  public let mediaDirectoryURL: URL

  /// Invoked after any save that enqueued outbox rows. `VaultStoreRegistry`
  /// routes this into the sync engine's local-mutation stream.
  let onLocalMutation: @Sendable () -> Void

  /// Opens (creating on first access) the vault's store. Opening performs no
  /// writes — a remotely discovered vault must not seed rows the server owns;
  /// `seedVaultInfo` is a separate, explicit step of the vault-creation flow.
  public static func open(
    vaultID: VaultID,
    layout: VaultStoreLayout,
    onLocalMutation: @escaping @Sendable () -> Void = {}
  ) throws -> VaultContentStore {
    try layout.ensureVaultDirectories(for: vaultID)
    let configuration = ModelConfiguration(
      schema: schema,
      url: layout.contentStoreURL(for: vaultID),
      cloudKitDatabase: .none  // sync is owned by VaultSyncEngine, never by SwiftData
    )
    let container = try ModelContainer(for: schema, configurations: configuration)
    return VaultContentStore(
      vaultID: vaultID,
      container: container,
      mediaDirectoryURL: layout.mediaDirectoryURL(for: vaultID),
      onLocalMutation: onLocalMutation
    )
  }

  /// On-disk location of an attachment's bytes.
  public func fileURL(for attachment: Attachment) -> URL {
    fileURL(forAttachmentID: attachment.id)
  }

  public func fileURL(forAttachmentID id: UUID) -> URL {
    mediaDirectoryURL.appending(path: id.uuidString, directoryHint: .notDirectory)
  }

  /// Whether this vault has no user-authored cards yet.
  ///
  /// Startup migration uses this as its one-shot gate. `VaultInfo`,
  /// `PendingMutation`, and sync metadata do not count as content because a newly
  /// created vault can have those rows before the user has any cards.
  @MainActor
  public func isEmptyForStartupMigration() throws -> Bool {
    let context = container.mainContext
    return try context.fetchCount(FetchDescriptor<Card>()) == 0
  }
}

// MARK: - Errors

extension VaultContentStore {

  public enum Error: Swift.Error {
    case cardNotFound(UUID)
    case missingMediaPayload(Card.Kind)
  }
}

// MARK: - Drafts

extension VaultContentStore {

  /// Persistence-ready input for one card in a composed post. The app converts
  /// capture-component values into these primitives at the write boundary, so
  /// capture frameworks stay persistence-agnostic (same contract as the legacy
  /// `JournalStore.ThreadCardInput`).
  public struct CardDraft: Sendable {

    /// Primary modality of the card to create.
    public var kind: Card.Kind

    /// Textual payload for body-backed cards. `.text` stores written content;
    /// `.link` stores the canonical URL string. Media cards ignore it.
    public var text: String

    /// In-memory attachment bytes for photo, doodle, and Bauhaus cards.
    public var mediaData: Data?

    /// Temporary file URL for audio cards; the file is **moved** into the vault
    /// media directory at save time.
    public var mediaFileURL: URL?

    /// Optional small raster preview carried inside the CloudKit record.
    public var thumbnail: Data?

    /// Location to attach, if the user opted in and a fix was available.
    public var location: Coordinate?

    public init(
      kind: Card.Kind,
      text: String = "",
      mediaData: Data? = nil,
      mediaFileURL: URL? = nil,
      thumbnail: Data? = nil,
      location: Coordinate? = nil
    ) {
      self.kind = kind
      self.text = text
      self.mediaData = mediaData
      self.mediaFileURL = mediaFileURL
      self.thumbnail = thumbnail
      self.location = location
    }
  }
}

// MARK: - Migration Imports

extension VaultContentStore {

  /// One already-authored card being imported into a vault.
  ///
  /// The identifier is preserved from the source store so external references,
  /// attachments, and future deduplication can keep speaking about the same
  /// logical card after the vault migration.
  public struct MigratedCard: Sendable {
    public var id: UUID
    public var kind: Card.Kind
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var location: Coordinate?

    public init(
      id: UUID,
      kind: Card.Kind,
      body: String,
      createdAt: Date,
      updatedAt: Date,
      location: Coordinate? = nil
    ) {
      self.id = id
      self.kind = kind
      self.body = body
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.location = location
    }
  }

  /// One card placement being imported into a vault tree.
  ///
  /// A legacy linear thread becomes a root edge plus child edges. Standalone
  /// legacy cards become root edges, which keeps the post/thread shape fully
  /// fractal in the target store.
  public struct MigratedCardEdge: Sendable {
    public var id: UUID
    public var cardID: UUID
    public var parentEdgeID: UUID?
    public var sortIndex: Int
    public var layout: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
      id: UUID,
      cardID: UUID,
      parentEdgeID: UUID? = nil,
      sortIndex: Int = 0,
      layout: Data? = nil,
      createdAt: Date,
      updatedAt: Date
    ) {
      self.id = id
      self.cardID = cardID
      self.parentEdgeID = parentEdgeID
      self.sortIndex = sortIndex
      self.layout = layout
      self.createdAt = createdAt
      self.updatedAt = updatedAt
    }
  }

  /// One attachment row and optional local file being imported into a vault.
  ///
  /// `sourceFileURL` may be `nil` when the legacy row exists before its CKAsset
  /// file is local. The row still migrates; the sync mapper leaves the remote
  /// asset field untouched when no local file is available.
  public struct MigratedAttachment: Sendable {
    public var id: UUID
    public var cardID: UUID
    public var kind: Attachment.Kind
    public var byteSize: Int
    public var thumbnail: Data?
    public var createdAt: Date
    public var sourceFileURL: URL?

    public init(
      id: UUID,
      cardID: UUID,
      kind: Attachment.Kind,
      byteSize: Int,
      thumbnail: Data? = nil,
      createdAt: Date,
      sourceFileURL: URL? = nil
    ) {
      self.id = id
      self.cardID = cardID
      self.kind = kind
      self.byteSize = byteSize
      self.thumbnail = thumbnail
      self.createdAt = createdAt
      self.sourceFileURL = sourceFileURL
    }
  }

  /// Counts produced by a migration import.
  public struct MigrationImportResult: Sendable {
    public var insertedCards: Int
    public var updatedCards: Int
    public var insertedEdges: Int
    public var updatedEdges: Int
    public var insertedAttachments: Int
    public var updatedAttachments: Int
    public var copiedMediaFiles: Int

    public init(
      insertedCards: Int = 0,
      updatedCards: Int = 0,
      insertedEdges: Int = 0,
      updatedEdges: Int = 0,
      insertedAttachments: Int = 0,
      updatedAttachments: Int = 0,
      copiedMediaFiles: Int = 0
    ) {
      self.insertedCards = insertedCards
      self.updatedCards = updatedCards
      self.insertedEdges = insertedEdges
      self.updatedEdges = updatedEdges
      self.insertedAttachments = insertedAttachments
      self.updatedAttachments = updatedAttachments
      self.copiedMediaFiles = copiedMediaFiles
    }

    public var didChange: Bool {
      insertedCards > 0
        || updatedCards > 0
        || insertedEdges > 0
        || updatedEdges > 0
        || insertedAttachments > 0
        || updatedAttachments > 0
        || copiedMediaFiles > 0
    }

    public var changedRowCount: Int {
      insertedCards
        + updatedCards
        + insertedEdges
        + updatedEdges
        + insertedAttachments
        + updatedAttachments
    }
  }
}

// MARK: - Writing

extension VaultContentStore {

  /// Seeds the vault's self-describing `VaultInfo` row and queues its upload.
  ///
  /// Called once by the vault-creation flow. Opening an existing or remotely
  /// materialized vault must **not** call this — for a joined vault the row
  /// arrives from CloudKit, and a local placeholder would race the server's.
  @MainActor
  public func seedVaultInfo(title: String) throws {
    let context = container.mainContext
    guard try context.fetchCount(FetchDescriptor<VaultInfo>()) == 0 else { return }
    context.insert(VaultInfo(vaultID: vaultID.rawValue, title: title))
    try noteSave(.vaultInfo, recordName: vaultID.uuidString, in: context)
    try context.save()
    onLocalMutation()
  }

  /// Imports pre-existing content while preserving source identifiers.
  ///
  /// Startup migration calls this only when the target vault has no cards. The
  /// upsert behavior is still kept at this lower boundary so a failed transaction
  /// retry cannot duplicate rows or re-enqueue unchanged records.
  @MainActor
  @discardableResult
  public func importMigratedContent(
    cards migratedCards: [MigratedCard],
    edges migratedEdges: [MigratedCardEdge],
    attachments migratedAttachments: [MigratedAttachment]
  ) throws -> MigrationImportResult {
    let context = container.mainContext
    var result = MigrationImportResult()

    var cardsByID = Dictionary(
      uniqueKeysWithValues: try context.fetch(FetchDescriptor<Card>()).map { ($0.id, $0) }
    )
    var edgesByID = Dictionary(
      uniqueKeysWithValues: try context.fetch(FetchDescriptor<CardEdge>()).map { ($0.id, $0) }
    )
    var attachmentsByID = Dictionary(
      uniqueKeysWithValues: try context.fetch(FetchDescriptor<Attachment>()).map { ($0.id, $0) }
    )

    for migrated in migratedCards {
      if let existing = cardsByID[migrated.id] {
        guard apply(migrated, to: existing) else { continue }
        result.updatedCards += 1
        try noteSave(.card, recordName: existing.id.uuidString, in: context)
      } else {
        let card = Card(
          id: migrated.id,
          kind: migrated.kind,
          body: migrated.body,
          createdAt: migrated.createdAt,
          updatedAt: migrated.updatedAt,
          location: migrated.location
        )
        context.insert(card)
        cardsByID[card.id] = card
        result.insertedCards += 1
        try noteSave(.card, recordName: card.id.uuidString, in: context)
      }
    }

    for migrated in migratedEdges {
      if let existing = edgesByID[migrated.id] {
        guard apply(migrated, to: existing) else { continue }
        result.updatedEdges += 1
        try noteSave(.cardEdge, recordName: existing.id.uuidString, in: context)
      } else {
        let edge = CardEdge(
          id: migrated.id,
          cardID: migrated.cardID,
          parentEdgeID: migrated.parentEdgeID,
          sortIndex: migrated.sortIndex,
          layout: migrated.layout,
          createdAt: migrated.createdAt,
          updatedAt: migrated.updatedAt
        )
        context.insert(edge)
        edgesByID[edge.id] = edge
        result.insertedEdges += 1
        try noteSave(.cardEdge, recordName: edge.id.uuidString, in: context)
      }
    }

    for migrated in migratedAttachments {
      let copiedFile = try copyMigratedFileIfNeeded(migrated)

      if let existing = attachmentsByID[migrated.id] {
        let updated = apply(migrated, to: existing)
        guard updated || copiedFile else { continue }
        result.updatedAttachments += updated ? 1 : 0
        result.copiedMediaFiles += copiedFile ? 1 : 0
        try noteSave(.attachment, recordName: existing.id.uuidString, in: context)
      } else {
        let attachment = Attachment(
          id: migrated.id,
          cardID: migrated.cardID,
          kind: migrated.kind,
          byteSize: migrated.byteSize,
          thumbnail: migrated.thumbnail,
          createdAt: migrated.createdAt
        )
        context.insert(attachment)
        attachmentsByID[attachment.id] = attachment
        result.insertedAttachments += 1
        result.copiedMediaFiles += copiedFile ? 1 : 0
        try noteSave(.attachment, recordName: attachment.id.uuidString, in: context)
      }
    }

    guard result.didChange else { return result }

    try context.save()
    onLocalMutation()
    return result
  }

  /// Saves a post. Every save creates a root `CardEdge`; additional drafts
  /// become child edges of that root in authored order — the design rule that
  /// single cards and threads share one shape.
  ///
  /// - Returns: The created edges in authored order; the first is the root.
  @MainActor
  @discardableResult
  public func createThread(cards drafts: [CardDraft]) throws -> [CardEdge] {
    guard drafts.isEmpty == false else { return [] }
    let context = container.mainContext

    // A multi-card post is one save, but its authored order still matters to
    // date-sorted readers — stagger timestamps like the legacy store does.
    let threadCreatedAt = Date()
    var edges: [CardEdge] = []
    var rootEdgeID: UUID?

    for (offset, draft) in drafts.enumerated() {
      let createdAt = threadCreatedAt.addingTimeInterval(TimeInterval(offset) / 1000)

      let card = Card(
        kind: draft.kind,
        body: Self.body(for: draft),
        createdAt: createdAt,
        updatedAt: createdAt,
        location: draft.location
      )
      context.insert(card)
      try noteSave(.card, recordName: card.id.uuidString, in: context)

      let edge = CardEdge(
        cardID: card.id,
        parentEdgeID: rootEdgeID,
        sortIndex: rootEdgeID == nil ? 0 : offset - 1,
        createdAt: createdAt,
        updatedAt: createdAt
      )
      context.insert(edge)
      try noteSave(.cardEdge, recordName: edge.id.uuidString, in: context)
      if rootEdgeID == nil {
        rootEdgeID = edge.id
      }

      if let attachment = try stageAttachment(from: draft, cardID: card.id, in: context) {
        try noteSave(.attachment, recordName: attachment.id.uuidString, in: context)
      }

      edges.append(edge)
    }

    try context.save()
    onLocalMutation()
    return edges
  }

  /// Replaces the editable payload of an existing card.
  ///
  /// Updates are modeled as one card save plus an attachment replacement when
  /// the modality carries media. Removing old attachment rows and inserting the
  /// new row in the same transaction keeps CloudKit outbox state aligned with
  /// the visible card; old files are deleted only after the transaction commits.
  @MainActor
  public func updateCard(cardID: UUID, with draft: CardDraft) throws {
    try validateAttachmentPayloadIfNeeded(draft)

    let context = container.mainContext
    guard let card = try fetchCard(id: cardID, in: context) else {
      throw Error.cardNotFound(cardID)
    }

    let deletedMediaFileURLs = try deleteAttachments(for: card.id, in: context)

    card.kind = draft.kind
    card.body = Self.body(for: draft)
    card.location = draft.location
    card.updatedAt = Date()
    try noteSave(.card, recordName: card.id.uuidString, in: context)

    if let attachment = try stageAttachment(from: draft, cardID: card.id, in: context) {
      try noteSave(.attachment, recordName: attachment.id.uuidString, in: context)
    }

    try context.save()

    for url in deletedMediaFileURLs {
      try? FileManager.default.removeItem(at: url)
    }
    onLocalMutation()
  }

  /// Replaces a text card's body.
  @MainActor
  public func updateCardBody(cardID: UUID, body: String) throws {
    let context = container.mainContext
    guard let card = try fetchCard(id: cardID, in: context) else {
      throw Error.cardNotFound(cardID)
    }
    card.body = body
    card.updatedAt = Date()
    try noteSave(.card, recordName: card.id.uuidString, in: context)
    try context.save()
    onLocalMutation()
  }

  /// Deletes an edge and its entire subtree: descendant edges, their cards, and
  /// those cards' attachments (rows, outbox tombstones, and media files).
  ///
  /// The cascade is a domain rule here — not a SwiftData delete rule and not
  /// CloudKit record hierarchy — so local deletes and imported remote deletes
  /// go through the same explicit shape.
  @MainActor
  public func deleteCardEdge(edgeID: UUID) throws {
    let context = container.mainContext
    let allEdges = try context.fetch(FetchDescriptor<CardEdge>())
    guard let root = allEdges.first(where: { $0.id == edgeID }) else { return }

    var childrenByParent: [UUID: [CardEdge]] = [:]
    for edge in allEdges {
      if let parent = edge.parentEdgeID {
        childrenByParent[parent, default: []].append(edge)
      }
    }

    var subtree: [CardEdge] = []
    var stack = [root]
    while let edge = stack.popLast() {
      subtree.append(edge)
      stack.append(contentsOf: childrenByParent[edge.id] ?? [])
    }

    let cardIDs = Set(subtree.map(\.cardID))
    let cards = try context.fetch(FetchDescriptor<Card>()).filter { cardIDs.contains($0.id) }
    let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter { cardIDs.contains($0.cardID) }

    var mediaFileURLs: [URL] = []
    for attachment in attachments {
      mediaFileURLs.append(fileURL(for: attachment))
      try noteDelete(.attachment, recordName: attachment.id.uuidString, in: context)
      context.delete(attachment)
    }
    for card in cards {
      try noteDelete(.card, recordName: card.id.uuidString, in: context)
      context.delete(card)
    }
    for edge in subtree {
      try noteDelete(.cardEdge, recordName: edge.id.uuidString, in: context)
      context.delete(edge)
    }

    try context.save()

    // Files go after the transaction: a failed save must keep bytes for rows
    // that still exist.
    for url in mediaFileURLs {
      try? FileManager.default.removeItem(at: url)
    }
    onLocalMutation()
  }

  @MainActor
  private func stageAttachment(
    from draft: CardDraft,
    cardID: UUID,
    in context: ModelContext
  ) throws -> Attachment? {
    guard let attachmentKind = Self.attachmentKind(for: draft.kind) else {
      return nil
    }

    if let data = draft.mediaData {
      let attachment = Attachment(
        cardID: cardID,
        kind: attachmentKind,
        byteSize: data.count,
        thumbnail: draft.thumbnail
      )
      // File first, row second: a failed save leaves an orphan file, never a
      // row pointing at missing bytes.
      try data.write(to: fileURL(for: attachment), options: .atomic)
      context.insert(attachment)
      return attachment
    }

    if let sourceURL = draft.mediaFileURL {
      let byteSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let attachment = Attachment(
        cardID: cardID,
        kind: attachmentKind,
        byteSize: byteSize,
        thumbnail: draft.thumbnail
      )
      try FileManager.default.moveItem(at: sourceURL, to: fileURL(for: attachment))
      context.insert(attachment)
      return attachment
    }

    return nil
  }

  @MainActor
  private func validateAttachmentPayloadIfNeeded(_ draft: CardDraft) throws {
    guard Self.attachmentKind(for: draft.kind) != nil else { return }
    guard draft.mediaData != nil || draft.mediaFileURL != nil else {
      throw Error.missingMediaPayload(draft.kind)
    }
  }

  @MainActor
  private func deleteAttachments(
    for cardID: UUID,
    in context: ModelContext
  ) throws -> [URL] {
    let attachments = try context.fetch(FetchDescriptor<Attachment>())
      .filter { $0.cardID == cardID }

    var mediaFileURLs: [URL] = []
    for attachment in attachments {
      mediaFileURLs.append(fileURL(for: attachment))
      try noteDelete(.attachment, recordName: attachment.id.uuidString, in: context)
      context.delete(attachment)
    }
    return mediaFileURLs
  }

  private static func body(for draft: CardDraft) -> String {
    switch draft.kind {
    case .text, .link:
      return draft.text
    case .photo, .audio, .doodle, .bauhaus, .unknown:
      return ""
    }
  }

  private static func attachmentKind(for cardKind: Card.Kind) -> Attachment.Kind? {
    switch cardKind {
    case .text, .link, .unknown:
      return nil
    case .photo:
      return .photo
    case .audio:
      return .audio
    case .doodle:
      return .doodle
    case .bauhaus:
      return .bauhaus
    }
  }

  @MainActor
  private func apply(_ migrated: MigratedCard, to card: Card) -> Bool {
    var didChange = false
    if card.kind != migrated.kind {
      card.kind = migrated.kind
      didChange = true
    }
    if card.body != migrated.body {
      card.body = migrated.body
      didChange = true
    }
    if card.createdAt != migrated.createdAt {
      card.createdAt = migrated.createdAt
      didChange = true
    }
    if card.updatedAt != migrated.updatedAt {
      card.updatedAt = migrated.updatedAt
      didChange = true
    }
    if card.location != migrated.location {
      card.location = migrated.location
      didChange = true
    }
    return didChange
  }

  @MainActor
  private func apply(_ migrated: MigratedCardEdge, to edge: CardEdge) -> Bool {
    var didChange = false
    if edge.cardID != migrated.cardID {
      edge.cardID = migrated.cardID
      didChange = true
    }
    if edge.parentEdgeID != migrated.parentEdgeID {
      edge.parentEdgeID = migrated.parentEdgeID
      didChange = true
    }
    if edge.sortIndex != migrated.sortIndex {
      edge.sortIndex = migrated.sortIndex
      didChange = true
    }
    if edge.layout != migrated.layout {
      edge.layout = migrated.layout
      didChange = true
    }
    if edge.createdAt != migrated.createdAt {
      edge.createdAt = migrated.createdAt
      didChange = true
    }
    if edge.updatedAt != migrated.updatedAt {
      edge.updatedAt = migrated.updatedAt
      didChange = true
    }
    return didChange
  }

  @MainActor
  private func apply(_ migrated: MigratedAttachment, to attachment: Attachment) -> Bool {
    var didChange = false
    if attachment.cardID != migrated.cardID {
      attachment.cardID = migrated.cardID
      didChange = true
    }
    if attachment.kind != migrated.kind {
      attachment.kind = migrated.kind
      didChange = true
    }
    if attachment.byteSize != migrated.byteSize {
      attachment.byteSize = migrated.byteSize
      didChange = true
    }
    if attachment.thumbnail != migrated.thumbnail {
      attachment.thumbnail = migrated.thumbnail
      didChange = true
    }
    if attachment.createdAt != migrated.createdAt {
      attachment.createdAt = migrated.createdAt
      didChange = true
    }
    return didChange
  }

  private func copyMigratedFileIfNeeded(_ migrated: MigratedAttachment) throws -> Bool {
    guard let sourceFileURL = migrated.sourceFileURL else { return false }
    let destinationURL = fileURL(forAttachmentID: migrated.id)
    guard FileManager.default.fileExists(atPath: sourceFileURL.path) else { return false }
    guard FileManager.default.fileExists(atPath: destinationURL.path) == false else { return false }

    try FileManager.default.copyItem(at: sourceFileURL, to: destinationURL)
    return true
  }

  @MainActor
  private func fetchCard(id: UUID, in context: ModelContext) throws -> Card? {
    var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }
}

// MARK: - Outbox

extension VaultContentStore {

  /// Enqueues (or re-arms) the record's pending upload. Runs inside the write
  /// transaction; the caller saves.
  @MainActor
  private func noteSave(
    _ recordType: VaultRecordType,
    recordName: String,
    in context: ModelContext
  ) throws {
    if let existing = try fetchPendingMutation(recordName: recordName, in: context) {
      existing.kind = .save
      existing.enqueuedAt = Date()
      existing.stagedAt = nil
    } else {
      context.insert(
        PendingMutation(recordName: recordName, recordType: recordType.rawValue, kind: .save)
      )
    }
  }

  /// Enqueues the record's remote deletion. Runs inside the write transaction;
  /// the caller saves.
  @MainActor
  private func noteDelete(
    _ recordType: VaultRecordType,
    recordName: String,
    in context: ModelContext
  ) throws {
    let pending = try fetchPendingMutation(recordName: recordName, in: context)
    let hasSynced = try fetchSyncMetadata(recordName: recordName, in: context) != nil

    // A record that never reached CloudKit (no server metadata, pending save
    // never handed to a batch) needs no remote tombstone — dropping the
    // pending save is the whole delete.
    if hasSynced == false, let pending, pending.kind == .save, pending.stagedAt == nil {
      context.delete(pending)
      return
    }

    if let pending {
      pending.kind = .delete
      pending.enqueuedAt = Date()
      pending.stagedAt = nil
    } else {
      context.insert(
        PendingMutation(recordName: recordName, recordType: recordType.rawValue, kind: .delete)
      )
    }
  }

  @MainActor
  private func fetchPendingMutation(
    recordName: String,
    in context: ModelContext
  ) throws -> PendingMutation? {
    var descriptor = FetchDescriptor<PendingMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  @MainActor
  private func fetchSyncMetadata(
    recordName: String,
    in context: ModelContext
  ) throws -> SyncMetadata? {
    var descriptor = FetchDescriptor<SyncMetadata>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }
}
