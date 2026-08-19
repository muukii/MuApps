import Darwin
import Foundation
import Synchronization

/// Serializes one vault's SQLite transactions across Tinycurve processes.
///
/// The app, Share extension, and App Intent each own a distinct
/// `ModelContainer`, so SwiftData's per-container uniqueness checks cannot make
/// a fetch-then-insert singleton atomic between them. This coordinator holds an
/// advisory lock on a stable file in the vault directory around a complete
/// transaction. Authored writes, sync acknowledgement/import, retention, and
/// local Shared with You delivery all use this same boundary. The operating
/// system releases the POSIX lock when the process exits or closes its lock-file
/// descriptor, including after a crash.
struct VaultAuthoredWriteCoordinator: Sendable {

  /// Process-local locks supplement POSIX's process-owned record locks. They
  /// protect tests and any accidental second `ModelContainer` opened in one
  /// process, while the on-disk lock below protects app/extension processes.
  private static let inProcessLocks = Mutex<[URL: VaultInProcessWriteLock]>([:])

  /// The per-vault file used only as an operating-system lock identity.
  let lockFileURL: URL

  /// Runs `body` while no other Tinycurve process can mutate this vault store.
  ///
  /// `body` must be synchronous: holding the process-wide file lock across an
  /// `await` would unnecessarily block an extension or foreground app. Lock
  /// acquisition happens before any body mutation, so an open/lock failure
  /// leaves no staged rows or files for this invocation.
  @discardableResult
  func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
    let inProcessLock = Self.inProcessLock(for: lockFileURL)
    inProcessLock.lock()
    defer { inProcessLock.unlock() }

    let descriptor = try openLockFile()
    defer { _ = Darwin.close(descriptor) }

    try acquireExclusiveLock(on: descriptor)
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }

    return try body()
  }

  /// Opens the stable lock file, retrying only interruption by a signal.
  private func openLockFile() throws -> Int32 {
    while true {
      let descriptor = lockFileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
      }
      if descriptor >= 0 {
        return descriptor
      }
      guard errno == EINTR else {
        throw currentPOSIXError()
      }
    }
  }

  /// Acquires the advisory lock, allowing signal interruption without losing
  /// the caller's requested write.
  private func acquireExclusiveLock(on descriptor: Int32) throws {
    while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
      guard errno == EINTR else {
        throw currentPOSIXError()
      }
    }
  }

  /// Captures the C error immediately before another POSIX call can replace it.
  private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  /// Returns the one in-process companion for a stable vault lock-file URL.
  private static func inProcessLock(for lockFileURL: URL) -> VaultInProcessWriteLock {
    inProcessLocks.withLock { locks in
      if let existing = locks[lockFileURL] {
        return existing
      }
      let lock = VaultInProcessWriteLock()
      locks[lockFileURL] = lock
      return lock
    }
  }
}

/// Synchronous companion lock for independently opened stores in one process.
///
/// POSIX record locks belong to a process, so they do not make two file
/// descriptors owned by that same process wait for each other. The coordinator
/// combines this lock with `lockf` to provide the same authored-write invariant
/// for both local test containers and production's app/extension processes.
private final class VaultInProcessWriteLock: @unchecked Sendable {

  private let underlyingLock = NSLock()

  func lock() {
    underlyingLock.lock()
  }

  func unlock() {
    underlyingLock.unlock()
  }
}
