import Foundation
import SwiftData

/// One vault's content store: the local truth SwiftUI observes.
///
/// CloudKit mirroring is disabled by design — `VaultSyncEngine` owns CloudKit.
/// Every write here therefore does two things in one transaction: mutate the
/// content rows *and* enqueue matching `PendingMutation` outbox rows, so a
/// local change can never exist without its pending upload (and vice versa).
/// New authored posts additionally create their durable `VaultActivity`, local
/// Shared with You intent, and eligible notification Pulse in that transaction.
/// Every authored mutation enters the vault-scoped write coordinator before it
/// reads either domain or outbox state. This lets it safely coexist with the
/// sync actor's import, staging, and acknowledgement transactions even when
/// the app, Share extension, and App Intent hold separate SwiftData contexts.
///
/// The write API is `@MainActor` and works on `container.mainContext` — the
/// same context SwiftUI observes. The sync engine reads and writes the store
/// through its own background `ModelActor` (`VaultSyncDatabase`), never through
/// this API, so imports don't ping-pong back into the outbox.
public struct VaultContentStore: Sendable {

  /// Recovery behavior when SwiftData cannot open an existing vault store.
  ///
  /// The app-lifetime runtime may rebuild pre-release local data from CloudKit.
  /// Short-lived extensions must instead preserve the store and surface an
  /// error, because a transient cross-process open failure must never delete it.
  public enum OpenRecoveryPolicy: Equatable, Sendable {
    case resetPreReleaseStore
    case failWithoutReset
  }

  public static let schema = Schema([
    VaultInfo.self,
    Card.self,
    CardEdge.self,
    Attachment.self,
    AttachmentResource.self,
    SyncMetadata.self,
    PendingMutation.self,
    VaultActivity.self,
    VaultNotificationPulse.self,
    PendingSharedWithYouNotice.self,
  ])

  public let vaultID: VaultID

  public let container: ModelContainer

  /// Directory holding attachment bytes, inside the vault directory so media
  /// and rows share the same vault boundary.
  public let mediaDirectoryURL: URL

  /// Cross-process guard for complete vault-store transactions in this vault.
  ///
  /// Every process gets its own coordinator value, but all values lock the same
  /// App Group file. Authored writes use it to atomically create Activity,
  /// Pulse, and outbox rows; sync import, acknowledgement, retention, and
  /// Shared with You local delivery use the same identity so independently
  /// opened app, extension, and App Intent containers cannot overwrite a
  /// fresh transaction with stale context state.
  let authoredWriteCoordinator: VaultAuthoredWriteCoordinator

  /// Invoked after any save that enqueued outbox rows. `VaultStoreRegistry`
  /// routes this into the sync engine's local-mutation stream.
  let onLocalMutation: @Sendable () -> Void

  /// Opens (creating on first access) the vault's store. Opening performs no
  /// writes — a remotely discovered vault must not seed rows the server owns;
  /// `seedVaultInfo` is a separate, explicit step of the vault-creation flow.
  public static func open(
    vaultID: VaultID,
    layout: VaultStoreLayout,
    recoveryPolicy: OpenRecoveryPolicy = .resetPreReleaseStore,
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
      guard recoveryPolicy == .resetPreReleaseStore else {
        throw error
      }
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
      authoredWriteCoordinator: VaultAuthoredWriteCoordinator(
        lockFileURL: layout.authoredWriteLockFileURL(for: vaultID)
      ),
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
    case cardEdgeNotFound(UUID)
    case invalidCardEdgeTopology(UUID)
    case cardIsNotTodo(UUID)
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

    /// Textual payload for body-backed cards. `.text` and `.todo` store written
    /// content, `.link` stores the canonical URL string, and `.file` stores the
    /// original user-facing file name. Other media and authored JSON cards
    /// ignore it.
    public var text: String

    /// Completion timestamp to preserve when creating or editing a Todo.
    /// Other card kinds normalize this to `nil` at the write boundary.
    public var completedAt: Date?

    /// In-memory attachment bytes for photo, suggestion, doodle, and Bauhaus cards.
    public var mediaData: Data?

    /// Temporary file URL for audio cards; the file is **moved** into the vault
    /// media directory only after the save transaction commits.
    public var mediaFileURL: URL?

    /// Explicit file resources for compound media such as Live Photos and
    /// original videos.
    ///
    /// When empty, `mediaData` / `mediaFileURL` are converted into one primary
    /// resource using the card kind's default role. New media import paths should
    /// prefer this explicit shape so each file keeps its role and metadata.
    public var mediaResources: [AttachmentResourceDraft]

    /// Location to attach, if the user opted in and a fix was available.
    public var location: Coordinate?

    public init(
      kind: Card.Kind,
      text: String = "",
      completedAt: Date? = nil,
      mediaData: Data? = nil,
      mediaFileURL: URL? = nil,
      mediaResources: [AttachmentResourceDraft] = [],
      location: Coordinate? = nil
    ) {
      self.kind = kind
      self.text = text
      self.completedAt = kind == .todo ? completedAt : nil
      self.mediaData = mediaData
      self.mediaFileURL = mediaFileURL
      self.mediaResources = mediaResources
      self.location = location
    }
  }

  /// One resource to stage under a `CardDraft` attachment.
  ///
  /// Resources are staged in the vault media directory, then source-file moves
  /// are finalized only after the save transaction commits.
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
    /// App-owned temporary imports can be moved. The store stages them by copy
    /// and deletes the source only after commit, preserving retryability on
    /// failure. System-owned sources such as Journaling Suggestion media stay in
    /// `.copy` mode so the picker source remains untouched.
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

    /// Versioned Codable JSON for the audio resource's measured waveform.
    ///
    /// The payload stays optional so imported media and legacy audio resources
    /// remain valid without a derived waveform.
    public var waveformData: Data?

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
      waveformData: Data? = nil,
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
      self.waveformData = waveformData
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
  public func seedVaultInfo(title: String, icon: VaultIcon = .default) throws {
    let didSeed = try withFreshAuthoredWrite { context in
      guard try context.fetchCount(FetchDescriptor<VaultInfo>()) == 0 else { return false }

      do {
        context.insert(VaultInfo(vaultID: vaultID.rawValue, title: title, icon: icon))
        try noteSave(.vaultInfo, recordName: vaultID.uuidString, in: context)
        try context.save()
        return true
      } catch {
        context.rollback()
        throw error
      }
    }

    if didSeed {
      onLocalMutation()
    }
  }

  /// Updates the vault's shared display title and queues the `VaultInfo` save.
  ///
  /// `VaultInfo` is the sync-visible metadata record for a vault. Renaming it
  /// here keeps the local SwiftData row and CloudKit outbox in the same
  /// transaction, just like card writes.
  @MainActor
  @discardableResult
  public func renameVault(title: String) throws -> Bool {
    let didRename = try withFreshAuthoredWrite { context in
      let now = Date()

      if let info = try fetchVaultInfo(in: context) {
        guard info.title != title else { return false }
        info.title = title
        info.updatedAt = now
      } else {
        context.insert(
          VaultInfo(
            vaultID: vaultID.rawValue,
            title: title,
            createdAt: now,
            updatedAt: now
          )
        )
      }

      do {
        try noteSave(.vaultInfo, recordName: vaultID.uuidString, in: context)
        try context.save()
        return true
      } catch {
        context.rollback()
        throw error
      }
    }

    if didRename {
      onLocalMutation()
    }
    return didRename
  }

  /// Updates the vault's shared display icon and queues the `VaultInfo` save.
  ///
  /// `title` is used only to repair a missing metadata row. Normal owned and
  /// imported vaults already have `VaultInfo` before this method is called.
  @MainActor
  @discardableResult
  public func updateVaultIcon(_ icon: VaultIcon, title: String) throws -> Bool {
    let didUpdate = try withFreshAuthoredWrite { context in
      let now = Date()

      if let info = try fetchVaultInfo(in: context) {
        guard info.icon != icon else { return false }
        info.iconKindRawValue = icon.kind.rawValue
        info.iconValue = icon.value
        info.updatedAt = now
      } else {
        context.insert(
          VaultInfo(
            vaultID: vaultID.rawValue,
            title: title,
            icon: icon,
            createdAt: now,
            updatedAt: now
          )
        )
      }

      do {
        try noteSave(.vaultInfo, recordName: vaultID.uuidString, in: context)
        try context.save()
        return true
      } catch {
        context.rollback()
        throw error
      }
    }

    if didUpdate {
      onLocalMutation()
    }
    return didUpdate
  }

  /// Saves a post. Every save creates a root `CardEdge`; additional drafts
  /// become child edges of that root in authored order — the design rule that
  /// single cards and posts share one shape.
  ///
  /// The caller must supply a catalog-derived delivery policy. This store never
  /// reads `VaultCatalogStore`, so it cannot safely infer whether another
  /// participant currently exists while holding this content transaction.
  ///
  /// - Returns: The created edges in authored order; the first is the root.
  @MainActor
  @discardableResult
  public func createPost(
    cards drafts: [CardDraft],
    deliveryPolicy: VaultActivityDeliveryPolicy
  ) throws -> [CardEdge] {
    guard drafts.isEmpty == false else { return [] }

    // Validate the full authored post before mutating the context or staging
    // files. A missing child payload must not leave a partial post behind.
    for draft in drafts {
      try validateAttachmentPayloadIfNeeded(draft)
    }

    let committed = try withFreshAuthoredWrite {
      context -> (edges: [CardEdge], sourceFileURLsToDeleteAfterCommit: [URL]) in

      // A multi-card post is one save, but its authored order still matters to
      // date-sorted readers, so cards get tiny timestamp offsets.
      let postCreatedAt = Date()
      var edges: [CardEdge] = []
      var rootEdge: CardEdge?
      var destinationFileURLs: [URL] = []
      var sourceFileURLsToDeleteAfterCommit: [URL] = []

      do {
        for (offset, draft) in drafts.enumerated() {
          let createdAt = postCreatedAt.addingTimeInterval(TimeInterval(offset) / 1000)
          let stagedCardEdge = try stageCardEdge(
            from: draft,
            parent: rootEdge,
            sortIndex: rootEdge == nil ? 0 : offset - 1,
            createdAt: createdAt,
            in: context
          )
          if rootEdge == nil {
            rootEdge = stagedCardEdge.edge
          }
          destinationFileURLs.append(contentsOf: stagedCardEdge.destinationFileURLs)
          sourceFileURLsToDeleteAfterCommit.append(
            contentsOf: stagedCardEdge.sourceFileURLsToDeleteAfterCommit
          )
          edges.append(stagedCardEdge.edge)
        }

        guard let rootEdge else {
          preconditionFailure("A non-empty post must create its root CardEdge.")
        }
        try stageAuthoredActivity(
          subjectEdgeID: rootEdge.id,
          rootEdgeID: rootEdge.id,
          createdAt: postCreatedAt,
          deliveryPolicy: deliveryPolicy,
          in: context
        )
        try context.save()
        return (edges, sourceFileURLsToDeleteAfterCommit)
      } catch {
        context.rollback()
        for fileURL in destinationFileURLs {
          try? FileManager.default.removeItem(at: fileURL)
        }
        throw error
      }
    }

    // Source files are no longer needed only after the SQLite transaction has
    // committed. Keep the OS lock narrowly scoped to shared vault state; a
    // slow source-file cleanup must not delay another process's authored save.
    for fileURL in Set(committed.sourceFileURLsToDeleteAfterCommit) {
      try? FileManager.default.removeItem(at: fileURL)
    }
    onLocalMutation()
    return committed.edges
  }

  /// Appends one authored card directly below an existing placement.
  ///
  /// The parent lookup, sibling order, content rows, attachment files, and
  /// CloudKit outbox rows commit as one transaction. This keeps every detail
  /// level fractal without ever exposing a temporary root placement to sync.
  /// The delivery policy is intentionally explicit for the same cross-store
  /// ownership reason as ``createPost(cards:deliveryPolicy:)``.
  @MainActor
  @discardableResult
  public func appendCard(
    _ draft: CardDraft,
    to parentEdgeID: UUID,
    deliveryPolicy: VaultActivityDeliveryPolicy
  ) throws -> CardEdge {
    try validateAttachmentPayloadIfNeeded(draft)

    let committed = try withFreshAuthoredWrite {
      context -> (edge: CardEdge, sourceFileURLsToDeleteAfterCommit: [URL]) in
      let allEdges = try context.fetch(FetchDescriptor<CardEdge>())
      guard
        let parentEdge = allEdges.first(where: { $0.id == parentEdgeID }),
        parentEdge.deletedAt == nil
      else {
        throw Error.cardEdgeNotFound(parentEdgeID)
      }

      // Parent resolution and the next sibling index read shared local state,
      // so they must use the same cross-process critical section as the save.
      let nextSortIndex =
        allEdges
        .lazy
        .filter { $0.parentEdgeID == parentEdgeID }
        .map(\.sortIndex)
        .max()
        .map { $0 + 1 }
        ?? 0
      let rootEdgeID = try resolvedRootEdgeID(startingAt: parentEdge, allEdges: allEdges)
      let createdAt = Date()
      var destinationFileURLs: [URL] = []

      do {
        let stagedCardEdge = try stageCardEdge(
          from: draft,
          parent: parentEdge,
          sortIndex: nextSortIndex,
          createdAt: createdAt,
          in: context
        )
        destinationFileURLs = stagedCardEdge.destinationFileURLs
        try stageAuthoredActivity(
          subjectEdgeID: stagedCardEdge.edge.id,
          rootEdgeID: rootEdgeID,
          createdAt: createdAt,
          deliveryPolicy: deliveryPolicy,
          in: context
        )
        try context.save()
        return (stagedCardEdge.edge, stagedCardEdge.sourceFileURLsToDeleteAfterCommit)
      } catch {
        context.rollback()
        for fileURL in destinationFileURLs {
          try? FileManager.default.removeItem(at: fileURL)
        }
        throw error
      }
    }

    for fileURL in Set(committed.sourceFileURLsToDeleteAfterCommit) {
      try? FileManager.default.removeItem(at: fileURL)
    }
    onLocalMutation()
    return committed.edge
  }

  /// Returns the newest top-level card, ignoring every continuation depth.
  ///
  /// Widget selection and Home chronology are anchored to root placements.
  ///
  /// Home may render each root's subtree, but only roots participate in its day
  /// grouping and the Latest Note widget. Root resolution uses the stable edge
  /// reference so a temporarily unrepaired relationship cannot make a child
  /// appear as top-level content.
  @MainActor
  public func latestRootCard() throws -> Card? {
    let context = container.mainContext
    let edges = try context.fetch(
      FetchDescriptor<CardEdge>(
        sortBy: [
          SortDescriptor(\.createdAt, order: .reverse),
          SortDescriptor(\.id),
        ]
      )
    )

    for edge in edges where edge.parentEdgeID == nil && edge.deletedAt == nil {
      if let card = edge.card, card.id == edge.cardID {
        return card
      }
      if let card = try fetchCard(id: edge.cardID, in: context) {
        return card
      }
    }
    return nil
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

    let committed = try withFreshAuthoredWrite {
      context -> (deletedMediaFileURLs: [URL], sourceFileURLsToDeleteAfterCommit: [URL]) in
      guard let card = try fetchCard(id: cardID, in: context) else {
        throw Error.cardNotFound(cardID)
      }

      var deletedMediaFileURLs: [URL] = []
      var destinationFileURLs: [URL] = []
      var sourceFileURLsToDeleteAfterCommit: [URL] = []

      do {
        deletedMediaFileURLs = try deleteAttachments(for: card.id, in: context)

        card.kind = draft.kind
        card.body = Self.body(for: draft)
        card.completedAt = Self.completedAt(for: draft)
        card.location = draft.location
        card.updatedAt = Date()
        try noteSave(.card, recordName: card.id.uuidString, in: context)

        if let stagedAttachment = try stageAttachment(from: draft, card: card, in: context) {
          destinationFileURLs = stagedAttachment.destinationFileURLs
          sourceFileURLsToDeleteAfterCommit = stagedAttachment.sourceFileURLsToDeleteAfterCommit
          try noteSave(
            .attachment, recordName: stagedAttachment.attachment.id.uuidString, in: context)
          for resource in stagedAttachment.resources {
            try noteSave(.attachmentResource, recordName: resource.id.uuidString, in: context)
          }
        }

        try context.save()
        return (deletedMediaFileURLs, sourceFileURLsToDeleteAfterCommit)
      } catch {
        context.rollback()
        for fileURL in destinationFileURLs {
          try? FileManager.default.removeItem(at: fileURL)
        }
        throw error
      }
    }

    for url in committed.deletedMediaFileURLs {
      try? FileManager.default.removeItem(at: url)
    }
    for fileURL in Set(committed.sourceFileURLsToDeleteAfterCommit) {
      try? FileManager.default.removeItem(at: fileURL)
    }
    onLocalMutation()
  }

  /// Replaces a text card's body.
  @MainActor
  public func updateCardBody(cardID: UUID, body: String) throws {
    try withFreshAuthoredWrite { context in
      guard let card = try fetchCard(id: cardID, in: context) else {
        throw Error.cardNotFound(cardID)
      }

      do {
        card.body = body
        card.updatedAt = Date()
        try noteSave(.card, recordName: card.id.uuidString, in: context)
        try context.save()
      } catch {
        context.rollback()
        throw error
      }
    }

    onLocalMutation()
  }

  /// Completes or reopens one Todo without rewriting its authored body.
  ///
  /// The card mutation and its CloudKit outbox save commit in the same SwiftData
  /// transaction, matching every other user-visible vault write.
  ///
  /// - Returns: `true` when the completion state changed, or `false` when the
  ///   Todo already matched `isCompleted`.
  @MainActor
  @discardableResult
  public func setTodoCompletion(cardID: UUID, isCompleted: Bool) throws -> Bool {
    let didChange = try withFreshAuthoredWrite { context in
      guard let card = try fetchCard(id: cardID, in: context) else {
        throw Error.cardNotFound(cardID)
      }
      guard card.kind == .todo else {
        throw Error.cardIsNotTodo(cardID)
      }
      guard card.isCompleted != isCompleted else {
        return false
      }

      do {
        let now = Date()
        card.completedAt = isCompleted ? now : nil
        card.updatedAt = now
        try noteSave(.card, recordName: card.id.uuidString, in: context)
        try context.save()
        return true
      } catch {
        context.rollback()
        throw error
      }
    }

    if didChange {
      onLocalMutation()
    }
    return didChange
  }

  /// Logically deletes an edge and its entire subtree.
  ///
  /// Every placement receives the same local deletion timestamp while cards,
  /// attachments, resources, and media files remain in the vault. Matching
  /// CloudKit record deletes are enqueued in the same transaction so remote
  /// deletion begins immediately without detaching live SwiftData models.
  @MainActor
  public func deleteCardEdge(edgeID: UUID) throws {
    let didDelete = try withFreshAuthoredWrite { context in
      let allEdges = try context.fetch(FetchDescriptor<CardEdge>())
      guard
        let root = allEdges.first(where: { $0.id == edgeID }),
        root.deletedAt == nil
      else {
        return false
      }

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
      let attachments = try context.fetch(FetchDescriptor<Attachment>()).filter {
        cardIDs.contains($0.cardID)
      }
      let attachmentIDs = Set(attachments.map(\.id))
      let resources = try context.fetch(FetchDescriptor<AttachmentResource>())
        .filter { attachmentIDs.contains($0.attachmentID) }

      let deletedAt = Date()
      do {
        // Entry-level records lead the outbox so receiving devices can establish
        // logical deletion before processing attachment/resource tombstones.
        for edge in subtree {
          edge.deletedAt = deletedAt
          try noteDelete(.cardEdge, recordName: edge.id.uuidString, in: context)
        }
        for card in cards {
          try noteDelete(.card, recordName: card.id.uuidString, in: context)
        }
        for attachment in attachments {
          try noteDelete(.attachment, recordName: attachment.id.uuidString, in: context)
        }
        for resource in resources {
          try noteDelete(.attachmentResource, recordName: resource.id.uuidString, in: context)
        }
        try context.save()
        return true
      } catch {
        context.rollback()
        throw error
      }
    }

    if didDelete {
      onLocalMutation()
    }
  }

  /// Runs one local authored transaction against fresh durable vault state.
  ///
  /// `ModelContext` caches rows independently in the app, Share extension,
  /// and App Intent. Acquiring the same lock as ``VaultSyncDatabase`` and then
  /// rolling this context back prevents a stale UI context from overwriting a
  /// sync acknowledgement's outbox transition (or vice versa). The closure is
  /// synchronous by design: CloudKit, callbacks, and slow post-commit file
  /// deletion must stay outside this critical section.
  @MainActor
  private func withFreshAuthoredWrite<Result>(
    _ operation: (ModelContext) throws -> Result
  ) throws -> Result {
    try authoredWriteCoordinator.withExclusiveAccess {
      let context = container.mainContext
      context.rollback()
      context.processPendingChanges()
      return try operation(context)
    }
  }

  private struct StagedAttachment {
    var attachment: Attachment
    var resources: [AttachmentResource]
    var destinationFileURLs: [URL]
    var sourceFileURLsToDeleteAfterCommit: [URL]

    var primaryResource: AttachmentResource {
      resources[0]
    }
  }

  private struct StagedCardEdge {
    var edge: CardEdge
    var destinationFileURLs: [URL]
    var sourceFileURLsToDeleteAfterCommit: [URL]
  }

  /// Stages the non-content consequences of one locally authored logical
  /// action. It deliberately has no import or retry caller: imported records,
  /// edits, Todo changes, deletes, and sync retries are not new Activity.
  @MainActor
  private func stageAuthoredActivity(
    subjectEdgeID: UUID,
    rootEdgeID: UUID,
    createdAt: Date,
    deliveryPolicy: VaultActivityDeliveryPolicy,
    in context: ModelContext
  ) throws {
    let activity = VaultActivity(
      subjectEdgeID: subjectEdgeID,
      rootEdgeID: rootEdgeID,
      createdAt: createdAt
    )
    context.insert(activity)
    try noteSave(.activity, recordName: activity.recordName, in: context)

    switch deliveryPolicy {
    case .historyOnly:
      break
    case .notifyParticipants:
      // This row is intentionally local-only. Its presence proves the current
      // device authored a participant-visible action, so a later Shared with
      // You worker will not repost notices merely because it imported another
      // participant's Activity. History-only Activity intentionally has no
      // intent and can never become a retroactive notice after later sharing.
      context.insert(
        PendingSharedWithYouNotice(
          activityID: activity.id,
          createdAt: createdAt
        )
      )
      try stageNotificationPulse(for: activity, updatedAt: createdAt, in: context)
    }
  }

  /// Updates the vault's one mutable participant-notification trigger and
  /// re-arms its durable outbox row. `noteSave` clears `stagedAt`, preserving
  /// the existing `enqueuedAt` / `stagedAt` guarantee when a second post lands
  /// while the prior Pulse upload is in flight.
  @MainActor
  private func stageNotificationPulse(
    for activity: VaultActivity,
    updatedAt: Date,
    in context: ModelContext
  ) throws {
    let pulse: VaultNotificationPulse
    if let existing = try fetchNotificationPulse(in: context) {
      pulse = existing
      pulse.latestActivityRecordName = activity.recordName
      pulse.kindRawValue = activity.kindRawValue
      pulse.updatedAt = updatedAt
    } else {
      pulse = VaultNotificationPulse(
        latestActivityRecordName: activity.recordName,
        kind: activity.kind,
        updatedAt: updatedAt
      )
      context.insert(pulse)
    }

    try noteSave(.notificationPulse, recordName: pulse.recordName, in: context)
  }

  /// Inserts one card placement and stages its optional attachment without
  /// committing. Callers own the surrounding transaction and file cleanup.
  @MainActor
  private func stageCardEdge(
    from draft: CardDraft,
    parent: CardEdge?,
    sortIndex: Int,
    createdAt: Date,
    in context: ModelContext
  ) throws -> StagedCardEdge {
    let card = Card(
      kind: draft.kind,
      body: Self.body(for: draft),
      completedAt: Self.completedAt(for: draft),
      createdAt: createdAt,
      updatedAt: createdAt,
      location: draft.location
    )
    context.insert(card)
    try noteSave(.card, recordName: card.id.uuidString, in: context)

    let edge = CardEdge(
      cardID: card.id,
      parentEdgeID: parent?.id,
      sortIndex: sortIndex,
      createdAt: createdAt,
      updatedAt: createdAt
    )
    edge.connect(to: card)
    edge.connect(parent: parent)
    context.insert(edge)
    try noteSave(.cardEdge, recordName: edge.id.uuidString, in: context)

    guard let stagedAttachment = try stageAttachment(from: draft, card: card, in: context) else {
      return StagedCardEdge(
        edge: edge,
        destinationFileURLs: [],
        sourceFileURLsToDeleteAfterCommit: []
      )
    }

    do {
      try noteSave(.attachment, recordName: stagedAttachment.attachment.id.uuidString, in: context)
      for resource in stagedAttachment.resources {
        try noteSave(.attachmentResource, recordName: resource.id.uuidString, in: context)
      }
    } catch {
      for fileURL in stagedAttachment.destinationFileURLs {
        try? FileManager.default.removeItem(at: fileURL)
      }
      throw error
    }
    return StagedCardEdge(
      edge: edge,
      destinationFileURLs: stagedAttachment.destinationFileURLs,
      sourceFileURLsToDeleteAfterCommit:
        stagedAttachment.sourceFileURLsToDeleteAfterCommit
    )
  }

  @MainActor
  private func stageAttachment(
    from draft: CardDraft,
    card: Card,
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
      cardID: card.id,
      kind: attachmentKind,
      byteSize: Self.byteSize(for: resourceDrafts[0]),
      primaryResourceID: primaryResourceID
    )
    attachment.connect(to: card)

    var stagedResources: [AttachmentResource] = []
    var destinationFileURLs: [URL] = []
    var sourceFileURLsToDeleteAfterCommit: [URL] = []

    do {
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
          waveformData: resourceDraft.waveformData,
          isHDR: resourceDraft.isHDR,
          colorSpaceName: resourceDraft.colorSpaceName,
          createdAt: attachment.createdAt
        )
        resource.connect(to: attachment)

        let destinationURL = fileURL(for: resource)
        guard FileManager.default.fileExists(atPath: destinationURL.path) == false else {
          throw CocoaError(.fileWriteFileExists)
        }
        // Registration precedes I/O so rollback also removes a partially
        // written destination when the file operation itself throws.
        destinationFileURLs.append(destinationURL)

        // Stage bytes without consuming the source. A requested move is
        // finalized only after SwiftData commits, so any failure remains
        // retryable and cannot leave a row pointing at missing bytes.
        if let data = resourceDraft.data {
          try data.write(to: destinationURL, options: .atomic)
        } else if let sourceURL = resourceDraft.fileURL {
          try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
          switch resourceDraft.fileTransferMode {
          case .move:
            sourceFileURLsToDeleteAfterCommit.append(sourceURL)
          case .copy:
            break
          }
        }
        resource.noteLocalFileChange()

        context.insert(resource)
        stagedResources.append(resource)
      }
    } catch {
      for fileURL in destinationFileURLs {
        try? FileManager.default.removeItem(at: fileURL)
      }
      throw error
    }

    context.insert(attachment)
    return StagedAttachment(
      attachment: attachment,
      resources: stagedResources,
      destinationFileURLs: destinationFileURLs,
      sourceFileURLsToDeleteAfterCommit: sourceFileURLsToDeleteAfterCommit
    )
  }

  @MainActor
  private func validateAttachmentPayloadIfNeeded(_ draft: CardDraft) throws {
    guard let attachmentKind = Self.attachmentKind(for: draft.kind) else { return }
    let resourceDrafts = Self.resourceDrafts(for: draft, attachmentKind: attachmentKind)
    guard resourceDrafts.isEmpty == false else {
      throw Error.missingMediaPayload(draft.kind)
    }

    // Validate file-backed inputs before deleting the existing attachment.
    // The later transfer can therefore fail without first invalidating the
    // saved card for common missing-file and permission cases.
    for resourceDraft in resourceDrafts {
      guard let sourceURL = resourceDraft.fileURL else { continue }
      guard sourceURL.isFileURL,
        FileManager.default.fileExists(atPath: sourceURL.path)
      else {
        throw CocoaError(.fileReadNoSuchFile)
      }
      guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
        throw CocoaError(.fileReadNoPermission)
      }
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
    case .text, .todo, .link, .file:
      return draft.text
    case .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus, .unknown:
      return ""
    }
  }

  private static func completedAt(for draft: CardDraft) -> Date? {
    switch draft.kind {
    case .todo:
      return draft.completedAt
    case .text, .link, .file, .photo, .video, .livePhoto, .audio, .suggestion, .doodle,
      .bauhaus, .unknown:
      return nil
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

  private static func primaryResourceRole(for attachmentKind: Attachment.Kind)
    -> AttachmentResource.Role
  {
    switch attachmentKind {
    case .file:
      return .file
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
    case .file:
      return nil
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
    case .text, .todo, .link, .unknown:
      return nil
    case .file:
      return .file
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

  @MainActor
  private func fetchVaultInfo(in context: ModelContext) throws -> VaultInfo? {
    var descriptor = FetchDescriptor<VaultInfo>()
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  /// Fetches the fixed-name singleton Pulse. The unique record-name key keeps
  /// this defensive lookup stable across restarts and future background writes.
  @MainActor
  private func fetchNotificationPulse(
    in context: ModelContext
  ) throws -> VaultNotificationPulse? {
    let descriptor = FetchDescriptor<VaultNotificationPulse>()
    return try context.fetch(descriptor).first {
      $0.recordName == VaultNotificationPulse.fixedRecordName
    }
  }

  /// Walks parent IDs without trusting repaired SwiftData relationships.
  ///
  /// A remote import can temporarily leave a parent missing, or corrupt data
  /// can contain a cycle. Both states are rejected before a new Reply is
  /// persisted: inventing a root would make the new Activity point at a
  /// topology that the app cannot safely navigate or synchronize.
  @MainActor
  private func resolvedRootEdgeID(
    startingAt edge: CardEdge,
    allEdges: [CardEdge]
  ) throws -> UUID {
    let edgesByID = Dictionary(uniqueKeysWithValues: allEdges.map { ($0.id, $0) })
    var current = edge
    var resolvedRootID = edge.id
    var visited = Set<UUID>()

    while true {
      guard visited.insert(current.id).inserted else {
        throw Error.invalidCardEdgeTopology(current.id)
      }
      resolvedRootID = current.id
      guard let parentID = current.parentEdgeID else {
        return resolvedRootID
      }
      guard let parent = edgesByID[parentID] else {
        throw Error.invalidCardEdgeTopology(current.id)
      }
      current = parent
    }
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
      // The record name is the outbox uniqueness key. Keep its type current as
      // well so an old/corrupt row can never route a valid model to the wrong
      // CloudKit record type on its next retry.
      existing.recordType = recordType.rawValue
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
      pending.recordType = recordType.rawValue
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
