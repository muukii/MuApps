import CloudKit
import Foundation
import Testing

@testable import JournalVault

struct VaultActivityRetentionTests {

  @Test
  func policy_keepsAllActivitiesBelowThreshold() {
    let candidates = retentionCandidates(count: 1_199)

    let deletions = VaultActivityRetentionPolicy.deletionCandidates(from: candidates)

    #expect(deletions.isEmpty)
  }

  @Test
  func policy_atThresholdDeletesOldest200AndRetains1000() {
    let candidates = retentionCandidates(count: 1_200).reversed()

    let deletions = VaultActivityRetentionPolicy.deletionCandidates(from: Array(candidates))

    #expect(deletions.count == 200)
    #expect(deletions.map(\.recordName) == retentionCandidates(count: 200).map(\.recordName))
  }

  @Test
  func policy_aboveThresholdDeletesOnlyTheExcessOldestActivities() {
    let candidates = retentionCandidates(count: 1_201)

    let deletions = VaultActivityRetentionPolicy.deletionCandidates(from: candidates)

    #expect(deletions.count == 201)
    #expect(deletions.last?.recordName == retentionCandidates(count: 201).last?.recordName)
  }

  @Test
  func query_usesActivityTruePredicateOldestSortAndMinimalFields() {
    let query = VaultActivityRetentionCloudKitQuery.makeQuery()

    #expect(query.recordType == VaultRecordType.activity.rawValue)
    #expect(query.predicate.evaluate(with: nil))
    #expect(query.sortDescriptors?.count == 1)
    #expect(query.sortDescriptors?.first?.key == VaultRecordMapper.VaultActivityKey.createdAt)
    #expect(query.sortDescriptors?.first?.ascending == true)
    #expect(
      VaultActivityRetentionCloudKitQuery.desiredKeys
        == [VaultRecordMapper.VaultActivityKey.createdAt]
    )
    #expect(VaultActivityRetentionCloudKitQuery.pageSize == 200)
  }

  @Test
  func paginator_followsEachCursorBeforeReturningCandidates() async throws {
    let recorder = CursorPageRecorder()

    let candidates = try await VaultActivityRetentionPaginator.collect { (cursor: Int?) in
      await recorder.page(after: cursor)
    }

    #expect(candidates.map(\.recordName) == ["first", "second", "third"])
    #expect(await recorder.requestedCursors() == [nil, 1, 2])
  }

  @Test
  func paginator_abortsOnLaterPageFailureWithoutReturningPartialCandidates() async {
    let recorder = FailingCursorPageRecorder()

    do {
      _ = try await VaultActivityRetentionPaginator.collect { (cursor: Int?) in
        try await recorder.page(after: cursor)
      }
      Issue.record("Expected the second page failure to abort retention planning.")
    } catch RetentionTestError.partialFailure {
      #expect(await recorder.requestedCursors() == [nil, 1])
    } catch {
      Issue.record("Unexpected pagination error: \(error)")
    }
  }

  @Test
  func queryPage_abortsWhenAnyPerRecordResultFails() throws {
    let zoneID = CKRecordZone.ID(zoneName: "retention-test")
    let succeededRecordID = CKRecord.ID(recordName: "succeeded", zoneID: zoneID)
    let failedRecordID = CKRecord.ID(recordName: "failed", zoneID: zoneID)
    let succeededRecord = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: succeededRecordID
    )
    succeededRecord[VaultRecordMapper.VaultActivityKey.createdAt] = Date()

    do {
      _ = try VaultActivityRetentionCloudKitQuery.candidates(
        from: [
          (succeededRecordID, .success(succeededRecord)),
          (failedRecordID, .failure(RetentionTestError.perRecordFailure)),
        ]
      )
      Issue.record("Expected a per-record CloudKit result failure to abort the page.")
    } catch let error as VaultActivityRetentionQueryError {
      #expect(error == .recordResultFailed(recordName: failedRecordID.recordName))
    } catch {
      Issue.record("Unexpected per-record error: \(error)")
    }
  }

  @Test
  func queryPage_ignoresMalformedRecordNameBeforeItCanReachRetentionThreshold() throws {
    let malformedRecordName = "not-a-uuid"
    let matchResults = activityMatchResults(
      recordNames: validActivityRecordNames(count: 1_199) + [malformedRecordName]
    )

    let candidates = try VaultActivityRetentionCloudKitQuery.candidates(from: matchResults)
    let deletions = VaultActivityRetentionPolicy.deletionCandidates(from: candidates)

    #expect(candidates.count == 1_199)
    #expect(candidates.contains { $0.recordName == malformedRecordName } == false)
    #expect(deletions.isEmpty)
  }

  @Test
  func queryPage_neverDeletesFutureActivityIdentityAlongside1200KnownActivities() throws {
    let futureRecordName = "activity-v2:server-generated-identity"
    // Put the unsupported identity first so an unfiltered oldest-first plan
    // would incorrectly choose it for deletion at the 1,200 high-water mark.
    let matchResults = activityMatchResults(
      recordNames: [futureRecordName] + validActivityRecordNames(count: 1_200)
    )

    let candidates = try VaultActivityRetentionCloudKitQuery.candidates(from: matchResults)
    let deletions = VaultActivityRetentionPolicy.deletionCandidates(from: candidates)

    #expect(candidates.count == 1_200)
    #expect(candidates.contains { $0.recordName == futureRecordName } == false)
    #expect(deletions.count == 200)
    #expect(deletions.contains { $0.recordName == futureRecordName } == false)
  }

  @Test
  func coordinator_coalescesConcurrentSignalsForOneZoneWithoutOverlap() async {
    let probe = RetentionCoordinatorProbe()
    let coordinator = VaultActivityRetentionCoordinator { zone, generation in
      await probe.perform(zone, generation: generation)
    }
    let zone = VaultActivityRetentionZone(
      databaseScope: .privateDatabase,
      zoneName: "retention-test",
      ownerName: CKCurrentUserDefaultName
    )

    await coordinator.schedule(zone, generation: 7)
    await probe.waitForFirstInvocation()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<3 {
        group.addTask {
          await coordinator.schedule(zone, generation: 7)
        }
      }
    }
    await probe.releaseFirstInvocation()
    await coordinator.waitUntilIdle()

    #expect(await probe.invocationCount() == 2)
    #expect(await probe.maximumConcurrentInvocationCount() == 1)
  }

  @Test
  func generation_invalidatesOldAccountBeforeItsTransactionCanEnter() throws {
    let generation = VaultActivityRetentionGeneration()
    let oldAccountGeneration = generation.capture()

    generation.invalidate()
    let mutation = generation.withCurrentGeneration(oldAccountGeneration) {
      "old account mutation"
    }

    #expect(mutation == nil)
    #expect(generation.isCurrent(oldAccountGeneration) == false)
  }

  @Test
  func exactDescriptor_requiresScopeAndCompleteZoneIdentity() throws {
    let privateVaultID = try #require(VaultID(uuidString: UUID().uuidString))
    let privateDescriptor = VaultDescriptor(
      vaultID: privateVaultID,
      title: "Private",
      ownership: .owned
    )
    let sharedVaultID = try #require(VaultID(uuidString: UUID().uuidString))
    let sharedDescriptor = VaultDescriptor(
      vaultID: sharedVaultID,
      title: "Shared",
      ownership: .participant,
      zoneOwnerName: "owner-a"
    )
    let descriptors = [
      privateVaultID: privateDescriptor,
      sharedVaultID: sharedDescriptor,
    ]

    #expect(
      CloudKitVaultSyncEngine.exactDescriptor(
        for: privateDescriptor.zoneID,
        scope: .private,
        in: descriptors
      ) == privateDescriptor
    )
    #expect(
      CloudKitVaultSyncEngine.exactDescriptor(
        for: privateDescriptor.zoneID,
        scope: .shared,
        in: descriptors
      ) == nil
    )
    #expect(
      CloudKitVaultSyncEngine.exactDescriptor(
        for: CKRecordZone.ID(zoneName: sharedVaultID.zoneName, ownerName: "owner-b"),
        scope: .shared,
        in: descriptors
      ) == nil
    )
    #expect(
      CloudKitVaultSyncEngine.exactDescriptor(
        for: sharedDescriptor.zoneID,
        scope: .private,
        in: descriptors
      ) == nil
    )
  }

  @Test
  func deleteSafety_failsClosedForUnknownIndeterminateAndMissingDecisions() {
    let zoneID = CKRecordZone.ID(zoneName: "delete-safety")
    let knownID = CKRecord.ID(recordName: "known", zoneID: zoneID)
    let unknownID = CKRecord.ID(recordName: "unknown", zoneID: zoneID)
    let indeterminateID = CKRecord.ID(recordName: "indeterminate", zoneID: zoneID)
    let missingID = CKRecord.ID(recordName: "missing", zoneID: zoneID)
    let saveID = CKRecord.ID(recordName: "save", zoneID: zoneID)
    let changes: [CKSyncEngine.PendingRecordZoneChange] = [
      .deleteRecord(knownID),
      .deleteRecord(unknownID),
      .deleteRecord(indeterminateID),
      .deleteRecord(missingID),
      .saveRecord(saveID),
    ]

    let filtered = CloudKitVaultSyncEngine.filteringOutboxDeletes(
      changes,
      decisions: [
        knownID: .eligible,
        unknownID: .unknownFutureType,
        indeterminateID: .indeterminate,
      ]
    )

    #expect(filtered == [.deleteRecord(knownID), .saveRecord(saveID)])
  }

  @Test
  func deleteBatchCap_preservesSavesAndDrainsRemainingDeletesInLaterBatch() {
    let zoneID = CKRecordZone.ID(zoneName: "retention-test")
    let deleteChanges: [CKSyncEngine.PendingRecordZoneChange] = (0..<205).map { index in
      .deleteRecord(CKRecord.ID(recordName: "delete-\(index)", zoneID: zoneID))
    }
    let saveOne = CKSyncEngine.PendingRecordZoneChange.saveRecord(
      CKRecord.ID(recordName: "save-one", zoneID: zoneID)
    )
    let saveTwo = CKSyncEngine.PendingRecordZoneChange.saveRecord(
      CKRecord.ID(recordName: "save-two", zoneID: zoneID)
    )
    let firstDeletes = Array(deleteChanges.prefix(100))
    let remainingDeletes = Array(deleteChanges.dropFirst(100))
    let pending = firstDeletes + [saveOne] + remainingDeletes + [saveTwo]

    let firstBatch = CloudKitVaultSyncEngine.limitingDeleteChanges(pending)
    let remaining = pending.filter { firstBatch.contains($0) == false }
    let secondBatch = CloudKitVaultSyncEngine.limitingDeleteChanges(remaining)

    #expect(deleteCount(in: firstBatch) == 200)
    #expect(firstBatch.contains(saveOne))
    #expect(firstBatch.contains(saveTwo))
    #expect(deleteRecordNames(in: firstBatch) == (0..<200).map { "delete-\($0)" })
    #expect(deleteCount(in: secondBatch) == 5)
    #expect(deleteRecordNames(in: secondBatch) == (200..<205).map { "delete-\($0)" })
  }

  private func retentionCandidates(count: Int) -> [VaultActivityRetentionCandidate] {
    validActivityRecordNames(count: count).enumerated().map { index, recordName in
      VaultActivityRetentionCandidate(
        recordName: recordName,
        createdAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
  }

  /// Generates UUID-shaped CloudKit record names owned by the current Activity
  /// import contract, without relying on random test data.
  private func validActivityRecordNames(count: Int) -> [String] {
    (0..<count).map { index in
      String(format: "00000000-0000-0000-0000-%012d", index)
    }
  }

  /// Builds ordered CloudKit results with an oldest-first timestamp sequence.
  private func activityMatchResults(
    recordNames: [String]
  ) -> [(CKRecord.ID, Result<CKRecord, any Error>)] {
    let zoneID = CKRecordZone.ID(zoneName: "retention-test")
    return recordNames.enumerated().map { index, recordName in
      let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
      let record = CKRecord(recordType: VaultRecordType.activity.rawValue, recordID: recordID)
      record[VaultRecordMapper.VaultActivityKey.createdAt] = Date(
        timeIntervalSince1970: TimeInterval(index)
      )
      let result: Result<CKRecord, any Error> = .success(record)
      return (recordID, result)
    }
  }

  private func deleteCount(in changes: [CKSyncEngine.PendingRecordZoneChange]) -> Int {
    changes.reduce(into: 0) { count, change in
      if case .deleteRecord = change {
        count += 1
      }
    }
  }

  private func deleteRecordNames(
    in changes: [CKSyncEngine.PendingRecordZoneChange]
  ) -> [String] {
    changes.compactMap { change in
      guard case .deleteRecord(let recordID) = change else { return nil }
      return recordID.recordName
    }
  }
}

private enum RetentionTestError: Error {
  case partialFailure
  case perRecordFailure
}

private actor CursorPageRecorder {

  private var cursors: [Int?] = []

  func page(after cursor: Int?) -> VaultActivityRetentionPage<Int> {
    cursors.append(cursor)
    switch cursor {
    case nil:
      return VaultActivityRetentionPage(
        candidates: [retentionCandidate(recordName: "first", time: 1)],
        nextCursor: 1
      )
    case 1:
      return VaultActivityRetentionPage(
        candidates: [retentionCandidate(recordName: "second", time: 2)],
        nextCursor: 2
      )
    default:
      return VaultActivityRetentionPage(
        candidates: [retentionCandidate(recordName: "third", time: 3)],
        nextCursor: nil
      )
    }
  }

  func requestedCursors() -> [Int?] {
    cursors
  }
}

private actor FailingCursorPageRecorder {

  private var cursors: [Int?] = []

  func page(after cursor: Int?) throws -> VaultActivityRetentionPage<Int> {
    cursors.append(cursor)
    switch cursor {
    case nil:
      return VaultActivityRetentionPage(
        candidates: [retentionCandidate(recordName: "first", time: 1)],
        nextCursor: 1
      )
    case 1:
      throw RetentionTestError.partialFailure
    default:
      Issue.record("Paginator requested a page after the injected partial failure.")
      return VaultActivityRetentionPage(candidates: [], nextCursor: nil)
    }
  }

  func requestedCursors() -> [Int?] {
    cursors
  }
}

private actor RetentionCoordinatorProbe {

  private var invocationCountValue = 0
  private var concurrentInvocationCount = 0
  private var maximumConcurrentInvocationCountValue = 0
  private var firstInvocationContinuation: CheckedContinuation<Void, Never>?
  private var releaseFirstInvocationContinuation: CheckedContinuation<Void, Never>?

  func perform(_: VaultActivityRetentionZone, generation _: UInt64) async {
    invocationCountValue += 1
    concurrentInvocationCount += 1
    maximumConcurrentInvocationCountValue = max(
      maximumConcurrentInvocationCountValue,
      concurrentInvocationCount
    )

    if invocationCountValue == 1 {
      firstInvocationContinuation?.resume()
      firstInvocationContinuation = nil
      await withCheckedContinuation { continuation in
        releaseFirstInvocationContinuation = continuation
      }
    }

    concurrentInvocationCount -= 1
  }

  func waitForFirstInvocation() async {
    guard invocationCountValue == 0 else { return }
    await withCheckedContinuation { continuation in
      firstInvocationContinuation = continuation
    }
  }

  func releaseFirstInvocation() {
    releaseFirstInvocationContinuation?.resume()
    releaseFirstInvocationContinuation = nil
  }

  func invocationCount() -> Int {
    invocationCountValue
  }

  func maximumConcurrentInvocationCount() -> Int {
    maximumConcurrentInvocationCountValue
  }
}

private func retentionCandidate(
  recordName: String,
  time: TimeInterval
) -> VaultActivityRetentionCandidate {
  VaultActivityRetentionCandidate(
    recordName: recordName,
    createdAt: Date(timeIntervalSince1970: time)
  )
}
