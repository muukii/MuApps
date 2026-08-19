import CloudKit
import Foundation
import Synchronization

/// One server-authoritative Activity selected for history retention.
///
/// `recordName` is the durable CloudKit identity and `createdAt` establishes
/// the oldest-first deletion order. The retention query requests no other
/// user fields, so it cannot accidentally treat history cleanup as authored
/// content or notification work.
struct VaultActivityRetentionCandidate: Hashable, Sendable {
  let recordName: String
  let createdAt: Date
}

/// Decides which server Activities should become durable delete tombstones.
///
/// The policy intentionally works from the fully paginated server query rather
/// than the local SwiftData cache. A device can be missing older history while
/// CloudKit still needs it deleted to keep every participant's retained window
/// bounded consistently.
enum VaultActivityRetentionPolicy {

  static let cleanupThreshold = 1_200
  static let retainedActivityCount = 1_000

  /// Returns exactly the oldest records that must be deleted to retain 1,000
  /// Activities once CloudKit contains 1,200 or more.
  static func deletionCandidates(
    from candidates: [VaultActivityRetentionCandidate]
  ) -> [VaultActivityRetentionCandidate] {
    let orderedCandidates = candidates.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.recordName < rhs.recordName
    }
    guard orderedCandidates.count >= cleanupThreshold else { return [] }
    return Array(orderedCandidates.prefix(orderedCandidates.count - retainedActivityCount))
  }
}

/// A typed page used by the query adapter and deterministic pagination tests.
///
/// Keeping the cursor generic lets the policy be exercised with a simple test
/// token while production carries CloudKit's opaque `CKQueryOperation.Cursor`.
struct VaultActivityRetentionPage<Cursor: Sendable>: Sendable {
  let candidates: [VaultActivityRetentionCandidate]
  let nextCursor: Cursor?
}

/// Collects all pages before retention mutates any local state.
///
/// A thrown query, cursor, or per-record error escapes before the caller can
/// enqueue a delete tombstone. This is the critical partial-failure boundary:
/// cleanup either acts on the complete server result or does nothing.
enum VaultActivityRetentionPaginator {

  static func collect<Cursor: Sendable>(
    fetchPage: (Cursor?) async throws -> VaultActivityRetentionPage<Cursor>
  ) async throws -> [VaultActivityRetentionCandidate] {
    var cursor: Cursor?
    var candidates: [VaultActivityRetentionCandidate] = []

    while true {
      let page = try await fetchPage(cursor)
      candidates.append(contentsOf: page.candidates)

      guard let nextCursor = page.nextCursor else { return candidates }
      cursor = nextCursor
    }
  }
}

/// Errors which make a server query unsafe to use for retention.
enum VaultActivityRetentionQueryError: Error, Equatable, Sendable {
  case recordResultFailed(recordName: String)
  case unexpectedRecordType(recordName: String)
  case missingCreatedAt(recordName: String)
}

/// CloudKit adapter for a single exact record zone.
///
/// `CKDatabase` returns individual `Result` values even when the query itself
/// succeeds. Mapping them here, before pagination reaches the policy, prevents
/// a partial page from deleting any local or remote Activity history.
struct VaultActivityRetentionCloudKitQuery {

  static let pageSize = 200
  static let desiredKeys: [CKRecord.FieldKey] = [VaultRecordMapper.VaultActivityKey.createdAt]

  let database: CKDatabase

  /// Fetches the complete ordered Activity history for exactly one custom zone.
  func activityCandidates(in zoneID: CKRecordZone.ID) async throws
    -> [VaultActivityRetentionCandidate]
  {
    try await VaultActivityRetentionPaginator.collect {
      (cursor: CKQueryOperation.Cursor?) in
      if let cursor {
        let result = try await database.records(
          continuingMatchFrom: cursor,
          desiredKeys: Self.desiredKeys,
          resultsLimit: Self.pageSize
        )
        return try VaultActivityRetentionPage(
          candidates: Self.candidates(from: result.matchResults),
          nextCursor: result.queryCursor
        )
      }

      let result = try await database.records(
        matching: Self.makeQuery(),
        inZoneWith: zoneID,
        desiredKeys: Self.desiredKeys,
        resultsLimit: Self.pageSize
      )
      return try VaultActivityRetentionPage(
        candidates: Self.candidates(from: result.matchResults),
        nextCursor: result.queryCursor
      )
    }
  }

  /// Constructs the server-authoritative, oldest-first Activity query.
  static func makeQuery() -> CKQuery {
    let query = CKQuery(
      recordType: VaultRecordType.activity.rawValue,
      predicate: NSPredicate(format: "TRUEPREDICATE")
    )
    query.sortDescriptors = [
      NSSortDescriptor(key: VaultRecordMapper.VaultActivityKey.createdAt, ascending: true)
    ]
    return query
  }

  /// Converts every result in one CloudKit page or fails the page as a whole.
  ///
  /// Only record names that the current build can materialize as
  /// ``VaultActivity`` identities become candidates. A later build may use a
  /// different record-name format; this build must leave those rows out of
  /// both the retention count and any delete tombstone rather than treating an
  /// unknown history format as deletable Activity data.
  static func candidates(
    from matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)]
  ) throws -> [VaultActivityRetentionCandidate] {
    try matchResults.compactMap { recordID, result in
      let record: CKRecord
      do {
        record = try result.get()
      } catch {
        throw VaultActivityRetentionQueryError.recordResultFailed(
          recordName: recordID.recordName
        )
      }

      // `VaultSyncDatabase` imports Activity rows by UUID. Filter future or
      // malformed identities at the CloudKit boundary, before pagination can
      // contribute them to the high-water threshold.
      guard UUID(uuidString: recordID.recordName) != nil else {
        return nil
      }
      guard record.recordType == VaultRecordType.activity.rawValue else {
        throw VaultActivityRetentionQueryError.unexpectedRecordType(recordName: recordID.recordName)
      }
      guard let createdAt = record[VaultRecordMapper.VaultActivityKey.createdAt] as? Date else {
        throw VaultActivityRetentionQueryError.missingCreatedAt(recordName: recordID.recordName)
      }
      return VaultActivityRetentionCandidate(recordName: recordID.recordName, createdAt: createdAt)
    }
  }
}

/// A stable identity for one independently coalesced server retention task.
///
/// The same vault ID can be visible through distinct private and shared
/// databases, so scope participates in the key as well as the exact zone ID.
struct VaultActivityRetentionZone: Hashable, Sendable {

  enum DatabaseScope: Hashable, Sendable {
    case privateDatabase
    case sharedDatabase
  }

  let databaseScope: DatabaseScope
  let zoneName: String
  let ownerName: String

  init(databaseScope: DatabaseScope, zoneName: String, ownerName: String) {
    self.databaseScope = databaseScope
    self.zoneName = zoneName
    self.ownerName = ownerName
  }

  init(scope: CKDatabase.Scope, zoneID: CKRecordZone.ID) {
    switch scope {
    case .shared:
      databaseScope = .sharedDatabase
    case .private, .public:
      databaseScope = .privateDatabase
    @unknown default:
      databaseScope = .privateDatabase
    }
    zoneName = zoneID.zoneName
    ownerName = zoneID.ownerName
  }

  var cloudKitDatabaseScope: CKDatabase.Scope {
    switch databaseScope {
    case .privateDatabase:
      .private
    case .sharedDatabase:
      .shared
    }
  }

  var cloudKitZoneID: CKRecordZone.ID {
    CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
  }
}

/// Account-scoped epoch protecting retention's query-to-tombstone boundary.
///
/// CloudKit can deliver an account-change callback while an old account's
/// server query is suspended. The engine invalidates this epoch before it
/// awaits task cancellation; the database then rechecks the captured value
/// while entering its synchronous SwiftData transaction. That final locked
/// check prevents old candidates from becoming tombstones even when the new
/// private account uses the same default owner name and vault UUID.
final class VaultActivityRetentionGeneration: Sendable {

  private let value = Mutex<UInt64>(0)

  func capture() -> UInt64 {
    value.withLock { $0 }
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    value.withLock { $0 == generation }
  }

  @discardableResult
  func invalidate() -> UInt64 {
    value.withLock { current in
      current &+= 1
      return current
    }
  }

  /// Enters a synchronous mutation only when `generation` is still current.
  func withCurrentGeneration<Result>(
    _ generation: UInt64,
    operation: () throws -> Result
  ) rethrows -> Result? {
    try value.withLock { current in
      guard current == generation else { return nil }
      return try operation()
    }
  }
}

/// Runs at most one cleanup at a time for each database-zone pair.
///
/// Additional acknowledgements while a query is in flight collapse into one
/// follow-up pass. This avoids duplicate delete planning while still ensuring a
/// save which lands during the first query is considered by a later pass.
actor VaultActivityRetentionCoordinator {

  typealias Operation = @Sendable (VaultActivityRetentionZone, UInt64) async -> Void

  private struct RunningTask {
    let identifier: UInt64
    let task: Task<Void, Never>
  }

  private let operation: Operation
  private var scheduledGenerations: [VaultActivityRetentionZone: UInt64] = [:]
  private var runningTasks: [VaultActivityRetentionZone: RunningTask] = [:]
  private var nextTaskIdentifier: UInt64 = 0

  init(operation: @escaping Operation) {
    self.operation = operation
  }

  func schedule(_ zone: VaultActivityRetentionZone, generation: UInt64) {
    scheduledGenerations[zone] = generation
    guard runningTasks[zone] == nil else { return }

    startScheduledWork(for: zone)
  }

  /// Cancels every old-account task and drops its coalesced follow-up signal.
  ///
  /// The running table is cleared before cancellation so a new account can
  /// schedule the same private zone immediately instead of waiting for an
  /// uncooperative CloudKit request from the previous account to return.
  func cancelAll() {
    scheduledGenerations.removeAll()
    let tasks = runningTasks.values.map(\.task)
    runningTasks.removeAll()
    for task in tasks {
      task.cancel()
    }
  }

  /// Test-only synchronization point that also makes the coordinator usable by
  /// a deterministic shutdown harness without cancelling in-flight cleanup.
  func waitUntilIdle() async {
    while let runningTask = runningTasks.values.first {
      await runningTask.task.value
    }
  }

  private func startScheduledWork(for zone: VaultActivityRetentionZone) {
    nextTaskIdentifier &+= 1
    let identifier = nextTaskIdentifier
    let task = Task {
      await self.runScheduledWork(for: zone, taskIdentifier: identifier)
    }
    runningTasks[zone] = RunningTask(identifier: identifier, task: task)
  }

  private func runScheduledWork(
    for zone: VaultActivityRetentionZone,
    taskIdentifier: UInt64
  ) async {
    while Task.isCancelled == false,
      let generation = scheduledGenerations.removeValue(forKey: zone)
    {
      await operation(zone, generation)
    }

    // A cancellation may have removed this task and allowed a new account's
    // task for the same zone to take its place. Never clear that replacement.
    guard runningTasks[zone]?.identifier == taskIdentifier else { return }
    runningTasks[zone] = nil
    if scheduledGenerations[zone] != nil {
      startScheduledWork(for: zone)
    }
  }
}
