//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// Bounds process-local access to Färg's expensive video encoding pipeline.
///
/// `BGContinuedProcessingTask` controls system runtime, not application
/// concurrency. Every in-process render entry point acquires this gate so the
/// current capacity of one remains explicit and can later become a measured
/// policy value without changing jobs or UI state.
actor VideoRenderResourceGate {

  /// Single policy value shared by the in-app scheduler and process gate.
  nonisolated static let productionCapacity = 1

  /// Production policy: only one AVFoundation/Core Image pipeline at a time.
  nonisolated static let shared = VideoRenderResourceGate(
    capacity: productionCapacity
  )

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  let capacity: Int

  private var availablePermits: Int
  private var waiters: [Waiter] = []

  /// Current FIFO depth, exposed internally for deterministic policy tests.
  var queuedCount: Int {
    waiters.count
  }

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.availablePermits = capacity
  }

  /// Runs one operation after a cancellation-safe FIFO permit is granted.
  ///
  /// The permit is returned for success, failure, and cancellation. A task
  /// cancelled while queued is removed without consuming future capacity.
  func withPermit<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await acquire()

    do {
      try Task.checkCancellation()
      let value = try await operation()
      release()
      return value
    } catch {
      release()
      throw error
    }
  }

  private func acquire() async throws {
    let waiterID = UUID()
    try Task.checkCancellation()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if availablePermits > 0 {
          availablePermits -= 1
          continuation.resume()
        } else {
          waiters.append(
            Waiter(id: waiterID, continuation: continuation)
          )
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release() {
    if waiters.isEmpty {
      availablePermits += 1
      precondition(availablePermits <= capacity)
    } else {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume()
    }
  }
}
