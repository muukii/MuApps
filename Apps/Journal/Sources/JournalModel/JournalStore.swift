import Foundation
import SwiftData

/// The shared persistence layer for the Journal app and its extensions.
///
/// The SwiftData store lives in the **App Group** container so the app process
/// and the Widget process read the same database; CloudKit mirroring keeps it
/// in sync across devices. Both the app target and every extension that needs
/// journal data must declare `appGroupIdentifier` in their entitlements, or the
/// shared container is inaccessible and `makeModelContainer()` throws.
///
/// This is the single source of truth for the schema and store location — never
/// build a `ModelContainer` for journal data anywhere else.
///
/// - Tag: JournalStore
public enum JournalStore {

  /// App Group backing the shared store. Listed under
  /// `com.apple.security.application-groups` in both the app and widget
  /// entitlements (see `Project.swift`).
  public static let appGroupIdentifier = "group.app.muukii.journal"

  /// The SwiftData schema. Every `@Model` type the store persists is registered
  /// here; the app and the widget must use the identical schema.
  public static let schema = Schema([
    Card.self,
    Tag.self,
    Attachment.self,
    CardRelationship.self,
  ])

  /// Builds the shared `ModelContainer`. Called by the app at launch and by the
  /// widget's timeline provider.
  ///
  /// `groupContainer: .identifier(...)` places the store inside the App Group
  /// container so both processes see the same file; `cloudKitDatabase:
  /// .automatic` mirrors it through the iCloud container declared in
  /// entitlements (`iCloud.app.muukii.journal`).
  public static func makeModelContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: schema,
      groupContainer: .identifier(appGroupIdentifier),
      cloudKitDatabase: .automatic
    )
    return try ModelContainer(for: schema, configurations: configuration)
  }
}

// MARK: - Errors

extension JournalStore {

  public enum Error: Swift.Error {
    /// The App Group container couldn't be resolved — the entitlement is missing
    /// or misconfigured (the same root cause that makes `makeModelContainer()` fail).
    case appGroupContainerUnavailable

    /// A card cannot be related to itself; that would be a cycle of length one.
    case relationshipToSelf

    /// Adding the requested edge would make the card graph cyclic.
    case relationshipWouldCreateCycle
  }
}

// MARK: - Writing

extension JournalStore {

  /// Persistence-ready input for one card in a composed thread.
  ///
  /// App-side draft state may keep rich capture values while the user edits. The
  /// store only receives normalized bytes / file URLs at the write boundary so
  /// `JournalModel` stays independent of capture frameworks.
  public struct ThreadCardInput: Sendable {

    /// Primary modality of the card to create.
    public var kind: Card.Kind

    /// Text body for `.text` cards. Media cards ignore it.
    public var text: String

    /// In-memory attachment bytes for photo, doodle, and Bauhaus cards.
    public var mediaData: Data?

    /// Temporary file URL for audio cards. The file is moved into the shared
    /// Journal media directory at save time.
    public var mediaFileURL: URL?

    /// Small mirrored preview data for media cards, when generated.
    public var mediaThumbnail: Data?

    /// Location to attach to the created card, if the user opted in and a fix
    /// was available.
    public var location: Coordinate?

    public init(
      kind: Card.Kind,
      text: String = "",
      mediaData: Data? = nil,
      mediaFileURL: URL? = nil,
      mediaThumbnail: Data? = nil,
      location: Coordinate? = nil
    ) {
      self.kind = kind
      self.text = text
      self.mediaData = mediaData
      self.mediaFileURL = mediaFileURL
      self.mediaThumbnail = mediaThumbnail
      self.location = location
    }
  }

  /// Creates a `Card` from captured content, inserts it into `context`, and saves
  /// immediately.
  ///
  /// Every writer funnels Card creation through here so the rules for turning
  /// captured input into a persisted Card live in one place instead of being
  /// scattered across `context.insert(Card(...))` call sites. The save is
  /// explicit — not left to SwiftData's autosave — so the caller can react to a
  /// write failure right away (e.g. keep the user's draft on screen).
  ///
  /// - Parameters:
  ///   - body: The note text. Callers pass already-trimmed, non-empty text;
  ///     rejecting empty input is a UI concern and is not enforced here. Ignored
  ///     for media card display.
  ///   - kind: The card modality. `.text` stores its primary content in `body`;
  ///     media kinds expect a matching attachment row.
  ///   - location: Where the card was created, when the user opted in to attach
  ///     it. `nil` (the default) leaves the card without a location.
  ///   - source: The previous card when this note continues an existing thread.
  ///     Passing `nil` creates a standalone card.
  ///   - context: The `ModelContext` to insert into (the app's main context).
  /// - Returns: The inserted `Card`.
  @MainActor
  @discardableResult
  public static func createCard(
    body: String,
    kind: Card.Kind = .text,
    location: Coordinate? = nil,
    continuingFrom source: Card? = nil,
    in context: ModelContext
  ) throws -> Card {
    let card = makeCard(kind: kind, body: body)
    card.location = location
    context.insert(card)
    if let source {
      let relationships = try context.fetch(FetchDescriptor<CardRelationship>())
      try insertRelationship(
        from: source,
        to: card,
        kind: .continuation,
        existingRelationships: relationships,
        in: context
      )
    }
    try context.save()
    return card
  }

  /// Creates a linear thread from composer drafts and saves it as one write.
  ///
  /// The first input becomes a standalone card unless `source` is provided. Each
  /// following input is connected to the card before it with a `.continuation`
  /// relationship, so the saved cards form the authored thread order.
  /// App-side draft state is converted into `ThreadCardInput` before this call:
  /// `kind` decides which fields are meaningful, `text` becomes `Card.body`, and
  /// `location` becomes `Card.location`.
  ///
  /// - Parameters:
  ///   - drafts: Composer drafts in authored order. Empty arrays are accepted
  ///     and return no cards.
  ///   - source: Existing card this thread continues from, if any.
  ///   - context: The `ModelContext` to insert into.
  /// - Returns: The inserted cards in the same order as `drafts`.
  @MainActor
  @discardableResult
  public static func createThread(
    cards drafts: [ThreadCardInput],
    continuingFrom source: Card? = nil,
    in context: ModelContext
  ) throws -> [Card] {
    guard drafts.isEmpty == false else { return [] }

    var relationships = try context.fetch(FetchDescriptor<CardRelationship>())
    var previousCard = source
    var createdCards: [Card] = []

    for draft in drafts {
      let card = makeCard(kind: draft.kind, body: draft.text)
      card.location = draft.location
      context.insert(card)
      try stageAttachment(from: draft, to: card, in: context)

      if let previousCard {
        let relationship = try insertRelationship(
          from: previousCard,
          to: card,
          kind: .continuation,
          existingRelationships: relationships,
          in: context
        )
        relationships.append(relationship)
      }

      createdCards.append(card)
      previousCard = card
    }

    try context.save()
    return createdCards
  }

  private static func makeCard(kind: Card.Kind, body: String) -> Card {
    switch kind {
    case .text:
      return Card(text: body)
    case .photo:
      return Card(photo: nil)
    case .audio:
      return Card(audio: nil)
    case .doodle:
      return Card(doodle: nil)
    case .bauhaus:
      return Card(bauhaus: nil)
    }
  }

  @MainActor
  private static func stageAttachment(
    from draft: ThreadCardInput,
    to card: Card,
    in context: ModelContext
  ) throws {
    switch draft.kind {
    case .text:
      break
    case .photo:
      if let mediaData = draft.mediaData {
        try stageDataAttachment(
          mediaData,
          kind: .photo,
          thumbnail: draft.mediaThumbnail,
          to: card,
          in: context
        )
      }
    case .audio:
      if let mediaFileURL = draft.mediaFileURL {
        try stageFileAttachment(
          movingFrom: mediaFileURL,
          kind: .audio,
          thumbnail: draft.mediaThumbnail,
          to: card,
          in: context
        )
      }
    case .doodle:
      if let mediaData = draft.mediaData {
        try stageDataAttachment(
          mediaData,
          kind: .doodle,
          thumbnail: draft.mediaThumbnail,
          to: card,
          in: context
        )
      }
    case .bauhaus:
      if let mediaData = draft.mediaData {
        try stageDataAttachment(
          mediaData,
          kind: .bauhaus,
          thumbnail: draft.mediaThumbnail,
          to: card,
          in: context
        )
      }
    }
  }
}

// MARK: - Relationships

extension JournalStore {

  /// Creates a directed relationship between two existing cards and saves it.
  ///
  /// Relationships make the card collection a directed acyclic graph. A thread is
  /// just a path through this graph; replies and references can branch from any
  /// earlier card. This writer is idempotent for the same `source` / `target` /
  /// `kind` triplet because CloudKit mirroring cannot enforce uniqueness.
  ///
  /// - Parameters:
  ///   - source: The card the edge starts from.
  ///   - target: The card the edge points to.
  ///   - kind: The domain meaning of the edge.
  ///   - context: The `ModelContext` to insert into.
  /// - Returns: The inserted relationship, or the existing equivalent edge.
  @MainActor
  @discardableResult
  public static func createRelationship(
    from source: Card,
    to target: Card,
    kind: CardRelationship.Kind = .continuation,
    in context: ModelContext
  ) throws -> CardRelationship {
    let relationships = try context.fetch(FetchDescriptor<CardRelationship>())
    let relationship = try insertRelationship(
      from: source,
      to: target,
      kind: kind,
      existingRelationships: relationships,
      in: context
    )
    try context.save()
    return relationship
  }

  @MainActor
  @discardableResult
  private static func insertRelationship(
    from source: Card,
    to target: Card,
    kind: CardRelationship.Kind,
    existingRelationships: [CardRelationship],
    in context: ModelContext
  ) throws -> CardRelationship {
    guard source.id != target.id else {
      throw Error.relationshipToSelf
    }

    if let existing = existingRelationship(
      from: source,
      to: target,
      kind: kind,
      relationships: existingRelationships
    ) {
      return existing
    }

    guard relationshipWouldCreateCycle(
      from: source,
      to: target,
      relationships: existingRelationships
    ) == false else {
      throw Error.relationshipWouldCreateCycle
    }

    let relationship = CardRelationship(
      kind: kind,
      sortIndex: nextSortIndex(from: source, kind: kind, relationships: existingRelationships),
      source: source,
      target: target
    )
    let now = Date()
    source.updatedAt = now
    target.updatedAt = now
    context.insert(relationship)
    return relationship
  }

  private static func existingRelationship(
    from source: Card,
    to target: Card,
    kind: CardRelationship.Kind,
    relationships: [CardRelationship]
  ) -> CardRelationship? {
    relationships.first { relationship in
      relationship.source?.id == source.id
        && relationship.target?.id == target.id
        && relationship.kind == kind
    }
  }

  private static func nextSortIndex(
    from source: Card,
    kind: CardRelationship.Kind,
    relationships: [CardRelationship]
  ) -> Int {
    let currentMax = relationships.compactMap { relationship -> Int? in
      guard relationship.source?.id == source.id, relationship.kind == kind else {
        return nil
      }
      return relationship.sortIndex
    }
    .max()

    return (currentMax ?? -1) + 1
  }

  private static func relationshipWouldCreateCycle(
    from source: Card,
    to target: Card,
    relationships: [CardRelationship]
  ) -> Bool {
    var adjacency: [UUID: [UUID]] = [:]
    for relationship in relationships {
      guard let sourceID = relationship.source?.id, let targetID = relationship.target?.id else {
        continue
      }
      adjacency[sourceID, default: []].append(targetID)
    }

    var visited: Set<UUID> = []
    var stack = adjacency[target.id] ?? []
    while let cardID = stack.popLast() {
      if cardID == source.id {
        return true
      }
      guard visited.insert(cardID).inserted else {
        continue
      }
      stack.append(contentsOf: adjacency[cardID] ?? [])
    }

    return false
  }
}

// MARK: - Media

extension JournalStore {

  /// Directory holding attachment files, inside the shared App Group container so
  /// the widget reads the same bytes. Created on first access.
  ///
  /// Bytes are stored here as files rather than inside the SwiftData store on
  /// purpose (see `Attachment`), so this directory is **not** CloudKit-mirrored —
  /// cross-device media sync is a separate, deliberate step still to come. It is
  /// covered by the device's iCloud backup in the meantime.
  public static func mediaDirectory() throws -> URL {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      throw Error.appGroupContainerUnavailable
    }
    let directory = container.appending(path: "Media", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// On-disk location of an attachment's bytes.
  public static func fileURL(for attachment: Attachment) throws -> URL {
    try mediaDirectory().appending(path: attachment.fileName, directoryHint: .notDirectory)
  }

  /// Attaches in-memory bytes (a photo's JPEG, encoded doodle JSON, or encoded
  /// Bauhaus artwork JSON) to `card`: writes
  /// the file, records an `Attachment`, and saves.
  ///
  /// The file is written *before* the row is inserted, so a failed save leaves an
  /// orphan file (reclaimed by `reconcileOrphanFiles`) rather than a row pointing at
  /// missing bytes. The host generates `thumbnail` and converts capture-component
  /// values into these primitives, so the capture frameworks stay persistence-agnostic.
  @MainActor
  @discardableResult
  public static func attachData(
    _ data: Data,
    kind: Attachment.Kind,
    thumbnail: Data? = nil,
    to card: Card,
    in context: ModelContext
  ) throws -> Attachment {
    let attachment = try stageDataAttachment(
      data,
      kind: kind,
      thumbnail: thumbnail,
      to: card,
      in: context
    )
    try context.save()
    return attachment
  }

  /// Attaches a file already on disk (an audio recording in the temporary directory)
  /// by **moving** it into the media directory — no second copy in memory, which
  /// matters for large recordings.
  @MainActor
  @discardableResult
  public static func attachFile(
    movingFrom sourceURL: URL,
    kind: Attachment.Kind,
    thumbnail: Data? = nil,
    to card: Card,
    in context: ModelContext
  ) throws -> Attachment {
    let attachment = try stageFileAttachment(
      movingFrom: sourceURL,
      kind: kind,
      thumbnail: thumbnail,
      to: card,
      in: context
    )
    try context.save()
    return attachment
  }

  /// Deletes an attachment row and its file. Cascade delete from `Card` already
  /// removes the row when a whole Card is deleted; call this to remove a single
  /// attachment on its own.
  @MainActor
  public static func deleteAttachment(_ attachment: Attachment, in context: ModelContext) throws {
    let url = try? fileURL(for: attachment)
    context.delete(attachment)
    try context.save()
    if let url {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Deletes media files that no `Attachment` row references — the file lifecycle's
  /// backstop. It reclaims files orphaned by a crash between writing the file and
  /// saving the row, **and** files left behind when a delete made on another device
  /// arrives via CloudKit (which removes the row, not the file).
  ///
  /// Safe to run at launch and after a sync import: it is keyed off the store as the
  /// source of truth, so it never removes a file that still has a live row.
  @MainActor
  public static func reconcileOrphanFiles(in context: ModelContext) throws {
    let directory = try mediaDirectory()
    let referenced = Set(try context.fetch(FetchDescriptor<Attachment>()).map(\.fileName))
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for file in files where referenced.contains(file.lastPathComponent) == false {
      try? FileManager.default.removeItem(at: file)
    }
  }

  @MainActor
  @discardableResult
  private static func stageDataAttachment(
    _ data: Data,
    kind: Attachment.Kind,
    thumbnail: Data?,
    to card: Card,
    in context: ModelContext
  ) throws -> Attachment {
    let attachment = Attachment(kind: kind, byteSize: data.count, thumbnail: thumbnail)
    attachment.card = card
    try data.write(to: fileURL(for: attachment), options: .atomic)
    context.insert(attachment)
    card.kind = Card.Kind(attachmentKind: kind)
    card.updatedAt = Date()
    return attachment
  }

  @MainActor
  @discardableResult
  private static func stageFileAttachment(
    movingFrom sourceURL: URL,
    kind: Attachment.Kind,
    thumbnail: Data?,
    to card: Card,
    in context: ModelContext
  ) throws -> Attachment {
    let byteSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let attachment = Attachment(kind: kind, byteSize: byteSize, thumbnail: thumbnail)
    attachment.card = card
    try FileManager.default.moveItem(at: sourceURL, to: fileURL(for: attachment))
    context.insert(attachment)
    card.kind = Card.Kind(attachmentKind: kind)
    card.updatedAt = Date()
    return attachment
  }
}
