import Foundation
import SwiftData

/// Record counts for one vault, grouped by CloudKit record type.
///
/// The same shape describes the rows a local store holds and the records
/// CloudKit currently stores, so a diagnostics surface can put both sides next
/// to each other while an import is still catching up.
public struct VaultRecordCountSnapshot: Equatable, Sendable {

  public var countsByRecordType: [VaultRecordType: Int]

  /// Records in the vault's CloudKit zone that Journal does not own, such as
  /// the zone-wide `cloudkit.share`. Always zero in a local snapshot.
  public var otherRecordCount: Int

  public init(
    countsByRecordType: [VaultRecordType: Int] = [:],
    otherRecordCount: Int = 0
  ) {
    self.countsByRecordType = countsByRecordType
    self.otherRecordCount = otherRecordCount
  }

  public func count(of recordType: VaultRecordType) -> Int {
    countsByRecordType[recordType] ?? 0
  }

  public var total: Int {
    countsByRecordType.values.reduce(0, +) + otherRecordCount
  }
}

/// What one vault's local store holds and what it still owes CloudKit.
public struct VaultLocalSyncCounts: Equatable, Sendable {

  public var records: VaultRecordCountSnapshot

  /// Durable outbox rows CloudKit has not acknowledged yet.
  public var pendingMutationCount: Int

  public init(
    records: VaultRecordCountSnapshot = .init(),
    pendingMutationCount: Int = 0
  ) {
    self.records = records
    self.pendingMutationCount = pendingMutationCount
  }
}

extension VaultContentStore {

  /// Counts this vault's rows for each CloudKit record type, plus its outbox
  /// depth.
  ///
  /// Unlike `cloudStorageEstimate()`, this counts rows rather than authored
  /// payload, and it keeps logically deleted rows because their CloudKit
  /// records can still exist. It answers "how far along is sync", not "how much
  /// does this vault store".
  @MainActor
  public func localSyncCounts() throws -> VaultLocalSyncCounts {
    let context = container.mainContext
    var countsByRecordType: [VaultRecordType: Int] = [:]

    for recordType in VaultRecordType.allCases {
      countsByRecordType[recordType] = try rowCount(of: recordType, in: context)
    }

    return VaultLocalSyncCounts(
      records: VaultRecordCountSnapshot(countsByRecordType: countsByRecordType),
      pendingMutationCount: try context.fetchCount(FetchDescriptor<PendingMutation>())
    )
  }

  @MainActor
  private func rowCount(
    of recordType: VaultRecordType,
    in context: ModelContext
  ) throws -> Int {
    switch recordType {
    case .vaultInfo:
      try context.fetchCount(FetchDescriptor<VaultInfo>())
    case .card:
      try context.fetchCount(FetchDescriptor<Card>())
    case .cardEdge:
      try context.fetchCount(FetchDescriptor<CardEdge>())
    case .attachment:
      try context.fetchCount(FetchDescriptor<Attachment>())
    case .attachmentResource:
      try context.fetchCount(FetchDescriptor<AttachmentResource>())
    case .activity:
      try context.fetchCount(FetchDescriptor<VaultActivity>())
    case .notificationPulse:
      try context.fetchCount(FetchDescriptor<VaultNotificationPulse>())
    }
  }
}
