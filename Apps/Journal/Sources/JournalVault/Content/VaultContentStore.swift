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
    AttachmentResource.self,
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
    let container: ModelContainer
    do {
      container = try ModelContainer(for: schema, configurations: configuration)
    } catch {
      // Journal is still pre-release. If an old local schema cannot migrate,
      // discard this vault's local content store instead of carrying migration
      // code for data shapes that never shipped.
      try layout.resetPreReleaseContentStoreForCloudKitRecovery(for: vaultID)
      container = try ModelContainer(for: schema, configurations: configuration)
    }
    return VaultContentStore(
      vaultID: vaultID,
      container: container,
      mediaDirectoryURL: layout.mediaDirectoryURL(for: vaultID),
      onLocalMutation: onLocalMutation
    )
  }

  /// On-disk location of one attachment resource's bytes.
  public func fileURL(for resource: AttachmentResource) -> URL {
    mediaDirectoryURL.appending(path: resource.fileName, directoryHint: .notDirectory)
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
  /// capture frameworks stay persistence-agnostic.
  public struct CardDraft: Sendable {

    /// Primary modality of the card to create.
    public var kind: Card.Kind

    /// Textual payload for body-backed cards. `.text` stores written content,
    /// and `.link` stores the canonical URL string. Media and authored JSON
    /// cards ignore it.
    public var text: String

    /// In-memory attachment bytes for photo, suggestion, doodle, and Bauhaus cards.
    public var mediaData: Data?

    /// Temporary file URL for audio cards; the file is **moved** into the vault
    /// media directory at save time.
    public var mediaFileURL: URL?

    /// Explicit file resources for compound media such as Live Photos and
    /// original videos.
    ///
    /// When empty, `mediaData` / `mediaFileURL` are converted into one primary
    /// resource using the card kind's default role. New media import paths should
    /// prefer this explicit shape so each file keeps its role and metadata.
    public var mediaResources: [AttachmentResourceDraft]

    /// Optional save-time raster derivative carried inside the CloudKit record.
    ///
    /// Use this for large raster media such as photos or future video poster
    /// frames. Vector/authored media should leave it empty and render from their
    /// media file instead.
    public var thumbnail: Data?

    /// Location to attach, if the user opted in and a fix was available.
    public var location: Coordinate?

    public init(
      kind: Card.Kind,
      text: String = "",
      mediaData: Data? = nil,
      mediaFileURL: URL? = nil,
      mediaResources: [AttachmentResourceDraft] = [],
      thumbnail: Data? = nil,
      location: Coordinate? = nil
    ) {
      self.kind = kind
      self.text = text
      self.mediaData = mediaData
      self.mediaFileURL = mediaFileURL
      self.mediaResources = mediaResources
      self.thumbnail = thumbnail
      self.location = location
    }
  }

  /// One resource to stage under a `CardDraft` attachment.
  ///
  /// Resources are moved or written into the vault media directory at save time.
  /// `role` is domain metadata, not a file extension; it tells renderers and
  /// sync/export code how the file participates in the logical attachment.
  public struct AttachmentResourceDraft: Sendable {

    /// Optional stable id to use for the stored resource row.
    ///
    /// Most import paths let the vault store generate ids. Suggestion cards use
    /// this to write the same id into their authored JSON resource so the JSON
    /// can point at copied media resources after sync.
    public var id: UUID?

    /// Semantic role of this file within its attachment.
    public var role: AttachmentResource.Role

    /// In-memory bytes for small resources or still images.
    public var data: Data?

    /// Temporary or system-provided file URL for larger resources.
    ///
    /// `fileTransferMode` decides whether the source is moved or copied into
    /// the vault.
    public var fileURL: URL?

    /// How `fileURL` should be transferred into the vault media directory.
    ///
    /// App-owned temporary imports can be moved. System-owned sources such as
    /// Journaling Suggestion media must be copied so the picker source remains
    /// untouched.
    public var fileTransferMode: FileTransferMode

    /// Optional byte count when the importer already knows it.
    public var byteSize: Int?

    /// UTI, MIME type, or another stable content type string.
    public var contentType: String?

    /// Pixel width for image/video resources when known.
    public var pixelWidth: Int?

    /// Pixel height for image/video resources when known.
    public var pixelHeight: Int?

    /// Duration in seconds for video/audio resources when known.
    public var duration: Double?

    /// Whether this resource contains HDR media.
    public var isHDR: Bool

    /// Color space name, when the importer can determine it.
    public var colorSpaceName: String?

    public init(
      id: UUID? = nil,
      role: AttachmentResource.Role,
      data: Data? = nil,
      fileURL: URL? = nil,
      fileTransferMode: FileTransferMode = .move,
      byteSize: Int? = nil,
      contentType: String? = nil,
      pixelWidth: Int? = nil,
      pixelHeight: Int? = nil,
      duration: Double? = nil,
      isHDR: Bool = false,
      colorSpaceName: String? = nil
    ) {
      self.id = id
      self.role = role
      self.data = data
      self.fileURL = fileURL
      self.fileTransferMode = fileTransferMode
      self.byteSize = byteSize
      self.contentType = contentType
      self.pixelWidth = pixelWidth
      self.pixelHeight = pixelHeight
      self.duration = duration
      self.isHDR = isHDR
      self.colorSpaceName = colorSpaceName
    }

    /// File transfer behavior when staging a resource from an existing URL.
    public enum FileTransferMode: Sendable {
      case move
      case copy
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
    // date-sorted readers, so cards get tiny timestamp offsets.
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

      if let stagedAttachment = try stageAttachment(from: draft, cardID: card.id, in: context) {
        try noteSave(.attachment, recordName: stagedAttachment.attachment.id.uuidString, in: context)
        for resource in stagedAttachment.resources {
          try noteSave(.attachmentResource, recordName: resource.id.uuidString, in: context)
        }
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

    if let stagedAttachment = try stageAttachment(from: draft, cardID: card.id, in: context) {
      try noteSave(.attachment, recordName: stagedAttachment.attachment.id.uuidString, in: context)
      for resource in stagedAttachment.resources {
        try noteSave(.attachmentResource, recordName: resource.id.uuidString, in: context)
      }
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
    let attachmentIDs = Set(attachments.map(\.id))
    let resources = try context.fetch(FetchDescriptor<AttachmentResource>())
      .filter { attachmentIDs.contains($0.attachmentID) }

    var mediaFileURLs: [URL] = []
    for resource in resources {
      mediaFileURLs.append(fileURL(for: resource))
      try noteDelete(.attachmentResource, recordName: resource.id.uuidString, in: context)
      context.delete(resource)
    }
    for attachment in attachments {
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

  private struct StagedAttachment {
    var attachment: Attachment
    var resources: [AttachmentResource]

    var primaryResource: AttachmentResource {
      resources[0]
    }
  }

  @MainActor
  private func stageAttachment(
    from draft: CardDraft,
    cardID: UUID,
    in context: ModelContext
  ) throws -> StagedAttachment? {
    guard let attachmentKind = Self.attachmentKind(for: draft.kind) else {
      return nil
    }

    let resourceDrafts = Self.resourceDrafts(for: draft, attachmentKind: attachmentKind)
    guard resourceDrafts.isEmpty == false else {
      return nil
    }

    let primaryResourceID = resourceDrafts[0].id ?? UUID()
    let attachment = Attachment(
      cardID: cardID,
      kind: attachmentKind,
      byteSize: Self.byteSize(for: resourceDrafts[0]),
      primaryResourceID: primaryResourceID,
      thumbnail: draft.thumbnail
    )

    var stagedResources: [AttachmentResource] = []
    for (index, resourceDraft) in resourceDrafts.enumerated() {
      let resource = AttachmentResource(
        id: resourceDraft.id ?? (index == 0 ? primaryResourceID : UUID()),
        attachmentID: attachment.id,
        role: resourceDraft.role,
        byteSize: Self.byteSize(for: resourceDraft),
        contentType: resourceDraft.contentType,
        pixelWidth: resourceDraft.pixelWidth,
        pixelHeight: resourceDraft.pixelHeight,
        duration: resourceDraft.duration,
        isHDR: resourceDraft.isHDR,
        colorSpaceName: resourceDraft.colorSpaceName,
        createdAt: attachment.createdAt
      )

      // File first, row second: a failed save leaves an orphan file, never a
      // row pointing at missing bytes.
      if let data = resourceDraft.data {
        try data.write(to: fileURL(for: resource), options: .atomic)
      } else if let sourceURL = resourceDraft.fileURL {
        switch resourceDraft.fileTransferMode {
        case .move:
          try FileManager.default.moveItem(at: sourceURL, to: fileURL(for: resource))
        case .copy:
          try FileManager.default.copyItem(at: sourceURL, to: fileURL(for: resource))
        }
      }

      context.insert(resource)
      stagedResources.append(resource)
    }

    context.insert(attachment)
    return StagedAttachment(attachment: attachment, resources: stagedResources)
  }

  @MainActor
  private func validateAttachmentPayloadIfNeeded(_ draft: CardDraft) throws {
    guard let attachmentKind = Self.attachmentKind(for: draft.kind) else { return }
    guard Self.resourceDrafts(for: draft, attachmentKind: attachmentKind).isEmpty == false else {
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
    let attachmentIDs = Set(attachments.map(\.id))
    let resources = try context.fetch(FetchDescriptor<AttachmentResource>())
      .filter { attachmentIDs.contains($0.attachmentID) }

    var mediaFileURLs: [URL] = []
    for resource in resources {
      mediaFileURLs.append(fileURL(for: resource))
      try noteDelete(.attachmentResource, recordName: resource.id.uuidString, in: context)
      context.delete(resource)
    }
    for attachment in attachments {
      try noteDelete(.attachment, recordName: attachment.id.uuidString, in: context)
      context.delete(attachment)
    }
    return mediaFileURLs
  }

  private static func body(for draft: CardDraft) -> String {
    switch draft.kind {
    case .text, .link:
      return draft.text
    case .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus, .unknown:
      return ""
    }
  }

  private static func resourceDrafts(
    for draft: CardDraft,
    attachmentKind: Attachment.Kind
  ) -> [AttachmentResourceDraft] {
    if draft.mediaResources.isEmpty == false {
      return draft.mediaResources.filter { $0.data != nil || $0.fileURL != nil }
    }

    let role = primaryResourceRole(for: attachmentKind)
    let contentType = contentType(for: attachmentKind)
    if let data = draft.mediaData {
      return [
        AttachmentResourceDraft(
          role: role,
          data: data,
          byteSize: data.count,
          contentType: contentType
        )
      ]
    }

    if let fileURL = draft.mediaFileURL {
      return [
        AttachmentResourceDraft(
          role: role,
          fileURL: fileURL,
          byteSize: fileByteSize(fileURL),
          contentType: contentType
        )
      ]
    }

    return []
  }

  private static func byteSize(for resource: AttachmentResourceDraft) -> Int {
    if let byteSize = resource.byteSize {
      return byteSize
    }

    if let data = resource.data {
      return data.count
    }

    if let fileURL = resource.fileURL {
      return fileByteSize(fileURL)
    }

    return 0
  }

  private static func fileByteSize(_ fileURL: URL) -> Int {
    (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private static func primaryResourceRole(for attachmentKind: Attachment.Kind) -> AttachmentResource.Role {
    switch attachmentKind {
    case .photo:
      return .originalImage
    case .video:
      return .originalVideo
    case .livePhoto:
      return .stillImage
    case .audio:
      return .audio
    case .suggestion, .doodle, .bauhaus:
      return .authoredJSON
    case .unknown:
      return .unknown
    }
  }

  private static func contentType(for attachmentKind: Attachment.Kind) -> String? {
    switch attachmentKind {
    case .photo:
      return "public.jpeg"
    case .video:
      return "public.mpeg-4"
    case .livePhoto:
      return nil
    case .audio:
      return "public.mpeg-4-audio"
    case .suggestion, .doodle, .bauhaus:
      return "public.json"
    case .unknown:
      return nil
    }
  }

  private static func attachmentKind(for cardKind: Card.Kind) -> Attachment.Kind? {
    switch cardKind {
    case .text, .link, .unknown:
      return nil
    case .photo:
      return .photo
    case .video:
      return .video
    case .livePhoto:
      return .livePhoto
    case .audio:
      return .audio
    case .suggestion:
      return .suggestion
    case .doodle:
      return .doodle
    case .bauhaus:
      return .bauhaus
    }
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
