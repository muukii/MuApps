@preconcurrency import LinkPresentation
import Foundation
import SwiftData

/// One device-local archived LinkPresentation response.
///
/// This row is cache data, not authored card content. It lives in a dedicated
/// SwiftData store under the app's Caches directory and never participates in
/// the JournalVault or CloudKit schemas.
@Model
final class LinkPreviewMetadataCacheEntry {

  /// Canonical absolute URL string used as the cache identity.
  @Attribute(.unique)
  var urlString: String

  /// Secure archive of the system-provided `LPLinkMetadata` object.
  var metadataArchive: Data

  /// Time at which the remote metadata was fetched.
  var fetchedAt: Date

  /// Most recently persisted access time used for least-recently-used trimming.
  /// Memory-hit timestamps are flushed on the next cache mutation.
  var lastAccessedAt: Date

  /// Archive size retained separately so capacity trimming need not decode blobs.
  var byteCount: Int

  init(
    urlString: String,
    metadataArchive: Data,
    fetchedAt: Date,
    lastAccessedAt: Date,
    byteCount: Int
  ) {
    self.urlString = urlString
    self.metadataArchive = metadataArchive
    self.fetchedAt = fetchedAt
    self.lastAccessedAt = lastAccessedAt
    self.byteCount = byteCount
  }
}

/// Main-actor owner of LinkPresentation memory and disk caches.
///
/// Lookups and writes are deliberately synchronous: memory access, SwiftData
/// queries, and metadata archiving share one serialized ownership boundary
/// without locks or actor hops. Remote metadata fetching remains asynchronous
/// and stays outside this storage type.
@MainActor
final class LinkPreviewMetadataCacheStorage {

  static let shared = LinkPreviewMetadataCacheStorage()

  /// In-process value paired with its original fetch time for expiration.
  private struct MemoryEntry {
    let metadata: LPLinkMetadata
    let fetchedAt: Date
    var lastAccessedAt: Date
  }

  private static let expirationInterval: TimeInterval = 7 * 24 * 60 * 60
  private static let maximumEntryCount = 200
  private static let maximumByteCount = 50 * 1_024 * 1_024

  private var memoryEntriesByURL: [String: MemoryEntry] = [:]
  private let modelContainer: ModelContainer?

  init(
    directoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.modelContainer = Self.makeModelContainer(
      directoryURL: directoryURL,
      fileManager: fileManager
    )
    trimCache(now: Date())
  }

  /// Returns fresh metadata from memory or the device-local SwiftData store.
  func metadata(for url: URL, now: Date = Date()) -> LPLinkMetadata? {
    let urlString = url.absoluteString

    if var memoryEntry = memoryEntriesByURL[urlString] {
      guard Self.isFresh(memoryEntry.fetchedAt, now: now) else {
        memoryEntriesByURL[urlString] = nil
        removeEntry(for: urlString)
        return nil
      }
      memoryEntry.lastAccessedAt = now
      memoryEntriesByURL[urlString] = memoryEntry
      return memoryEntry.metadata
    }

    guard
      let context = modelContainer?.mainContext,
      let persistedEntry = fetchEntry(for: urlString, in: context)
    else {
      return nil
    }

    guard Self.isFresh(persistedEntry.fetchedAt, now: now) else {
      context.delete(persistedEntry)
      saveOrRollback(context)
      return nil
    }

    do {
      guard let metadata = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: LPLinkMetadata.self,
        from: persistedEntry.metadataArchive
      ) else {
        context.delete(persistedEntry)
        saveOrRollback(context)
        return nil
      }

      memoryEntriesByURL[urlString] = MemoryEntry(
        metadata: metadata,
        fetchedAt: persistedEntry.fetchedAt,
        lastAccessedAt: now
      )
      persistedEntry.lastAccessedAt = now
      saveOrRollback(context)
      return metadata
    } catch {
      context.delete(persistedEntry)
      saveOrRollback(context)
      return nil
    }
  }

  /// Replaces cached metadata for a URL in memory and on disk.
  func store(_ metadata: LPLinkMetadata, for url: URL, now: Date = Date()) {
    let urlString = url.absoluteString
    memoryEntriesByURL[urlString] = MemoryEntry(
      metadata: metadata,
      fetchedAt: now,
      lastAccessedAt: now
    )

    guard
      let metadataArchive = try? NSKeyedArchiver.archivedData(
        withRootObject: metadata,
        requiringSecureCoding: true
      ),
      let context = modelContainer?.mainContext
    else {
      return
    }

    if let entry = fetchEntry(for: urlString, in: context) {
      entry.metadataArchive = metadataArchive
      entry.fetchedAt = now
      entry.lastAccessedAt = now
      entry.byteCount = metadataArchive.count
    } else {
      context.insert(
        LinkPreviewMetadataCacheEntry(
          urlString: urlString,
          metadataArchive: metadataArchive,
          fetchedAt: now,
          lastAccessedAt: now,
          byteCount: metadataArchive.count
        )
      )
    }

    saveOrRollback(context)
    trimCache(now: now)
  }

  private func fetchEntry(
    for urlString: String,
    in context: ModelContext
  ) -> LinkPreviewMetadataCacheEntry? {
    var descriptor = FetchDescriptor<LinkPreviewMetadataCacheEntry>(
      predicate: #Predicate { entry in
        entry.urlString == urlString
      }
    )
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  private func removeEntry(for urlString: String) {
    guard
      let context = modelContainer?.mainContext,
      let entry = fetchEntry(for: urlString, in: context)
    else {
      return
    }
    context.delete(entry)
    saveOrRollback(context)
  }

  private func trimCache(now: Date) {
    guard let context = modelContainer?.mainContext else {
      return
    }

    let descriptor = FetchDescriptor<LinkPreviewMetadataCacheEntry>()
    guard let entries = try? context.fetch(descriptor) else {
      return
    }

    var retainedEntries: [LinkPreviewMetadataCacheEntry] = []
    for entry in entries {
      if Self.isFresh(entry.fetchedAt, now: now) {
        if let memoryEntry = memoryEntriesByURL[entry.urlString] {
          entry.lastAccessedAt = max(entry.lastAccessedAt, memoryEntry.lastAccessedAt)
        }
        retainedEntries.append(entry)
      } else {
        memoryEntriesByURL[entry.urlString] = nil
        context.delete(entry)
      }
    }

    var remainingEntryCount = retainedEntries.count
    var remainingByteCount = retainedEntries.reduce(0) { $0 + $1.byteCount }

    for entry in retainedEntries.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
      guard
        remainingEntryCount > Self.maximumEntryCount
          || remainingByteCount > Self.maximumByteCount
      else {
        break
      }

      memoryEntriesByURL[entry.urlString] = nil
      context.delete(entry)
      remainingEntryCount -= 1
      remainingByteCount -= entry.byteCount
    }

    saveOrRollback(context)
  }

  private func saveOrRollback(_ context: ModelContext) {
    do {
      try context.save()
    } catch {
      context.rollback()
    }
  }

  private static func isFresh(_ fetchedAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(fetchedAt) <= expirationInterval
  }

  private static func makeModelContainer(
    directoryURL providedDirectoryURL: URL?,
    fileManager: FileManager
  ) -> ModelContainer? {
    let directoryURL: URL
    if let providedDirectoryURL {
      directoryURL = providedDirectoryURL
    } else {
      guard let cachesDirectory = fileManager.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first else {
        return nil
      }
      directoryURL = cachesDirectory.appending(
        path: "LinkPreviewMetadataCache",
        directoryHint: .isDirectory
      )
    }

    let storeURL = directoryURL.appending(
      path: "cache.store",
      directoryHint: .notDirectory
    )
    let schema = Schema([LinkPreviewMetadataCacheEntry.self])
    let configuration = ModelConfiguration(
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )

    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      return try ModelContainer(for: schema, configurations: configuration)
    } catch {
      // This database only contains disposable cache data. Recreate its exact
      // dedicated directory when an incompatible or corrupt store cannot open.
      try? fileManager.removeItem(at: directoryURL)
      try? fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      return try? ModelContainer(for: schema, configurations: configuration)
    }
  }
}
