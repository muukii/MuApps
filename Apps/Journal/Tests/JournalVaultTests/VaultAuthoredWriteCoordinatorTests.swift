import Dispatch
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import JournalVault

/// Exercises the coordinator's in-process companion separately from SwiftData.
/// A device harness remains responsible for proving the POSIX lock between the
/// app, Share extension, and App Intent processes.
@MainActor
struct VaultAuthoredWriteCoordinatorTests {

  @Test
  func twoOpenContainersSerializeTheFirstPulseCoordinator() throws {
    let vaultID = VaultID()
    let layout = makeTemporaryLayout()
    let firstStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    let secondStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )

    // Both containers were opened before either authored post. They must still
    // use the same vault-scoped lock identity when their processes later write.
    #expect(
      firstStore.authoredWriteCoordinator.lockFileURL
        == secondStore.authoredWriteCoordinator.lockFileURL
    )

    let gate = CoordinatorTestGate()
    let events = CoordinatorTestEvents()
    let errors = CoordinatorTestErrors()
    let writes = DispatchGroup()
    let firstCoordinator = firstStore.authoredWriteCoordinator
    let secondCoordinator = secondStore.authoredWriteCoordinator

    writes.enter()
    DispatchQueue.global().async {
      defer { writes.leave() }
      do {
        try firstCoordinator.withExclusiveAccess {
          events.append("first entered")
          gate.firstEntered.signal()
          gate.releaseFirst.wait()
          events.append("first exited")
        }
      } catch {
        errors.record(error)
      }
    }
    defer { gate.releaseFirst.signal() }

    #expect(gate.firstEntered.wait(timeout: .now() + 1) == .success)

    writes.enter()
    DispatchQueue.global().async {
      defer { writes.leave() }
      gate.secondAttempted.signal()
      do {
        try secondCoordinator.withExclusiveAccess {
          events.append("second entered")
          gate.secondEntered.signal()
        }
      } catch {
        errors.record(error)
      }
    }

    #expect(gate.secondAttempted.wait(timeout: .now() + 1) == .success)
    // The second descriptor has attempted the coordinator, but it cannot enter
    // until the first writer releases it. The process-local companion is what
    // makes this deterministic within one test process; `lockf` remains covered
    // by the separate-process device release gate.
    #expect(gate.secondEntered.wait(timeout: .now() + .milliseconds(200)) == .timedOut)

    gate.releaseFirst.signal()
    #expect(writes.wait(timeout: .now() + 1) == .success)
    #expect(errors.snapshot().isEmpty)
    #expect(events.snapshot() == ["first entered", "first exited", "second entered"])

    // Swift Testing runs these UI-main-actor APIs in one process, so it cannot
    // manufacture two simultaneous extension main actors. Keep the stale
    // two-container data regression beside the coordinator proof: the second
    // author sees and reuses the fixed singleton after the first commits.
    _ = try firstStore.createThread(
      cards: [.init(kind: .text, text: "from app")],
      deliveryPolicy: .notifyParticipants
    )
    _ = try secondStore.createThread(
      cards: [.init(kind: .text, text: "from extension")],
      deliveryPolicy: .notifyParticipants
    )

    let verificationStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    let context = verificationStore.container.mainContext
    #expect(try context.fetchCount(FetchDescriptor<VaultActivity>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 1)
    #expect(
      try context.fetch(FetchDescriptor<PendingMutation>())
        .filter { $0.recordName == VaultNotificationPulse.fixedRecordName }
        .count == 1
    )
  }

  @Test
  func lockAcquisitionFailureDoesNotRunTheAuthoredBody() throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    try layout.ensureVaultDirectories(for: vaultID)
    let coordinator = VaultAuthoredWriteCoordinator(
      // Opening a directory read/write as a file fails before `body` runs.
      lockFileURL: layout.vaultDirectoryURL(for: vaultID)
    )
    var didRunBody = false

    #expect(throws: (any Error).self) {
      try coordinator.withExclusiveAccess {
        didRunBody = true
      }
    }
    #expect(didRunBody == false)
  }
}

/// Test-only semaphore handoff that keeps the first file descriptor locked
/// until the second descriptor has attempted to enter the critical section.
private final class CoordinatorTestGate: @unchecked Sendable {

  let firstEntered = DispatchSemaphore(value: 0)
  let releaseFirst = DispatchSemaphore(value: 0)
  let secondAttempted = DispatchSemaphore(value: 0)
  let secondEntered = DispatchSemaphore(value: 0)
}

/// Thread-safe event recorder for asserting that the second writer entered
/// only after the first process-equivalent descriptor released its lock.
private final class CoordinatorTestEvents: @unchecked Sendable {

  private let values = Mutex<[String]>([])

  func append(_ value: String) {
    values.withLock { $0.append(value) }
  }

  func snapshot() -> [String] {
    values.withLock { $0 }
  }
}

/// Thread-safe failure recorder used by the synchronous Dispatch test workers.
private final class CoordinatorTestErrors: @unchecked Sendable {

  private let values = Mutex<[String]>([])

  func record(_ error: any Error) {
    values.withLock { $0.append(String(describing: error)) }
  }

  func snapshot() -> [String] {
    values.withLock { $0 }
  }
}
