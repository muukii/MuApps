//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import Observation
import OSLog

/// Identifies one rendered LUT result for a source frame and library revision.
struct LUTPreviewRequestID: Hashable, Sendable {

  /// The source still identity. A new stopped frame produces a new value.
  var sourceID: String
  /// The stable LUT identity.
  var lutID: String
  /// Invalidates a result when the LUT bytes change without changing its id.
  var libraryRevision: UInt
}

/// The source and library state shared by every LUT model on one screen.
struct LUTPreviewContextID: Hashable, Sendable {

  var sourceID: String?
  var libraryRevision: UInt
}

/// Holds one LUT's preview result independently of a lazy cell's lifetime.
///
/// A cell starts work when it appears, but this model owns that work after the
/// cell disappears. Reappearing cells therefore reuse the completed result.
@MainActor
@Observable
final class LUTPreviewModel: Identifiable {

  private static let logger = Logger(
    subsystem: "app.muukii.farg",
    category: "LUTPreview"
  )

  enum Phase: Equatable {
    case idle
    case loading
    case ready
    case failed
  }

  let id: String

  private(set) var renderedImage: CGImage?
  private(set) var phase: Phase = .idle

  private var activeRequestID: LUTPreviewRequestID?
  @ObservationIgnored private var renderTask: Task<Void, Never>?
  @ObservationIgnored private var isVisible = false
  @ObservationIgnored private let retainedResultDidChange:
    @MainActor @Sendable (String, Int) -> Void

  init(
    id: String,
    retainedResultDidChange:
      @escaping @MainActor @Sendable (String, Int) -> Void
  ) {
    self.id = id
    self.retainedResultDidChange = retainedResultDidChange
  }

  /// Returns a result only when it belongs to the cell's current request.
  func image(for requestID: LUTPreviewRequestID) -> CGImage? {
    guard activeRequestID == requestID else { return nil }
    return renderedImage
  }

  /// Returns failure state only for the cell's current request.
  func didFail(requestID: LUTPreviewRequestID) -> Bool {
    activeRequestID == requestID && phase == .failed
  }

  /// Starts background rendering once for the current source/LUT tuple.
  func appear(
    requestID: LUTPreviewRequestID,
    source: LUTPreviewSourceImage,
    recipe: LUTPreviewRecipe
  ) {
    isVisible = true
    Self.logger.debug(
      "Appear LUT \(self.id, privacy: .public), source \(requestID.sourceID, privacy: .public), revision \(requestID.libraryRevision)"
    )

    if activeRequestID == requestID {
      if let renderedImage {
        retainedResultDidChange(
          id,
          renderedImage.bytesPerRow * renderedImage.height
        )
      }
      guard phase == .idle else { return }
    } else {
      invalidate()
      activeRequestID = requestID
    }

    phase = .loading
    renderTask = Task { [weak self] in
      Self.logger.debug(
        "Start render LUT \(requestID.lutID, privacy: .public)"
      )
      do {
        let image = try await LUTPreviewRenderer.shared.render(
          source: source,
          recipe: recipe,
          libraryRevision: requestID.libraryRevision
        )
        guard
          let self,
          Task.isCancelled == false,
          self.activeRequestID == requestID
        else {
          return
        }
        self.renderedImage = image
        self.phase = .ready
        Self.logger.debug(
          "Finish render LUT \(requestID.lutID, privacy: .public)"
        )
        self.retainedResultDidChange(
          self.id,
          image.bytesPerRow * image.height
        )
      } catch is CancellationError {
        Self.logger.debug(
          "Cancel render LUT \(requestID.lutID, privacy: .public)"
        )
        return
      } catch {
        guard
          let self,
          Task.isCancelled == false,
          self.activeRequestID == requestID
        else {
          return
        }
        self.phase = .failed
        Self.logger.error(
          "Fail render LUT \(requestID.lutID, privacy: .public): \(error.localizedDescription)"
        )
      }
    }
  }

  /// Records a recipe-resolution failure for the current request.
  func fail(requestID: LUTPreviewRequestID) {
    guard activeRequestID != requestID || phase == .idle else { return }
    invalidate()
    activeRequestID = requestID
    phase = .failed
  }

  /// Marks the lazy cell as absent without cancelling already-started work.
  func disappear() {
    isVisible = false
  }

  /// Cancels obsolete work and releases a result after the source changes.
  func invalidate() {
    if let activeRequestID {
      Self.logger.debug(
        "Invalidate LUT \(self.id, privacy: .public), source \(activeRequestID.sourceID, privacy: .public), revision \(activeRequestID.libraryRevision)"
      )
    }
    renderTask?.cancel()
    renderTask = nil
    activeRequestID = nil
    phase = .idle
    if renderedImage != nil {
      renderedImage = nil
      retainedResultDidChange(id, 0)
    }
  }

  /// Cancels this model only when it still represents an older screen context.
  ///
  /// A cell's task and the screen's lifecycle callback may run in either order.
  /// Preserving an already-started request for the new context makes context
  /// updates independent of that ordering.
  fileprivate func invalidate(
    unlessMatching contextID: LUTPreviewContextID
  ) {
    guard
      let activeRequestID,
      contextID.sourceID == activeRequestID.sourceID,
      contextID.libraryRevision == activeRequestID.libraryRevision
    else {
      invalidate()
      return
    }
  }

  /// Releases a non-visible result selected by the screen-level memory budget.
  fileprivate func discardRetainedResult() {
    guard isVisible == false, renderedImage != nil else { return }
    renderedImage = nil
    phase = .idle
  }

  fileprivate var canDiscardRetainedResult: Bool {
    isVisible == false && renderedImage != nil
  }
}

/// Persists per-LUT preview models above lazy cells and bounds strong results.
///
/// Models are cheap and remain keyed by stable LUT identity. Their rendered
/// `CGImage`s are pixel-bounded and use a separate cost-limited LRU so a large
/// library cannot retain every rendered result.
@MainActor
@Observable
final class LUTPreviewModelStore {

  @ObservationIgnored private var modelsByID: [String: LUTPreviewModel] = [:]
  @ObservationIgnored private var contextID: LUTPreviewContextID?
  @ObservationIgnored private var retainedCosts: [String: Int] = [:]
  @ObservationIgnored private var retentionOrder: [String] = []
  @ObservationIgnored private var totalRetainedCost = 0

  private let retainedCostLimit: Int

  init(retainedCostLimit: Int = 48 * 1_024 * 1_024) {
    self.retainedCostLimit = retainedCostLimit
  }

  /// Returns the persisted model for one filter, creating it on first demand.
  ///
  /// SwiftUI lifecycle modifiers run after the first body evaluation. Creating
  /// lazily guarantees that even an initially visible cell gets a model before
  /// its appearance task starts; catalog synchronization then only prunes stale
  /// identities.
  func model(for lutID: String) -> LUTPreviewModel {
    if let model = modelsByID[lutID] {
      return model
    }
    let model = makeModel(id: lutID)
    modelsByID[lutID] = model
    return model
  }

  /// Adds and removes models only when the LUT catalog itself changes.
  func synchronize(lutIDs: [String]) {
    let requestedIDs = Set(lutIDs)
    let existingIDs = Set(modelsByID.keys)
    guard requestedIDs != existingIDs else { return }

    var updated = modelsByID
    for removedID in existingIDs.subtracting(requestedIDs) {
      updated.removeValue(forKey: removedID)?.invalidate()
      removeRetainedCost(for: removedID)
    }
    for addedID in requestedIDs.subtracting(existingIDs) {
      updated[addedID] = makeModel(id: addedID)
    }
    modelsByID = updated
  }

  /// Invalidates every filter when the stopped frame or LUT revision changes.
  func updateContext(_ contextID: LUTPreviewContextID) {
    guard let previousContextID = self.contextID else {
      // Cells can appear before the screen's initial lifecycle callbacks run.
      // Their request already uses this same context, so registration must not
      // cancel useful work that has just started.
      self.contextID = contextID
      return
    }
    guard previousContextID != contextID else { return }
    self.contextID = contextID
    for model in modelsByID.values {
      model.invalidate(unlessMatching: contextID)
    }
  }

  private func retainedResultDidChange(
    for lutID: String,
    cost: Int
  ) {
    removeRetainedCost(for: lutID)
    guard cost > 0 else { return }

    retainedCosts[lutID] = cost
    retentionOrder.append(lutID)
    totalRetainedCost += cost
    evictIfNeeded(excluding: lutID)
  }

  private func removeRetainedCost(for lutID: String) {
    if let existingCost = retainedCosts.removeValue(forKey: lutID) {
      totalRetainedCost -= existingCost
    }
    retentionOrder.removeAll { $0 == lutID }
  }

  private func evictIfNeeded(excluding protectedID: String) {
    while totalRetainedCost > retainedCostLimit {
      guard
        let index = retentionOrder.firstIndex(where: { lutID in
          lutID != protectedID
            && modelsByID[lutID]?.canDiscardRetainedResult == true
        })
      else {
        return
      }

      let evictedID = retentionOrder.remove(at: index)
      if let cost = retainedCosts.removeValue(forKey: evictedID) {
        totalRetainedCost -= cost
      }
      modelsByID[evictedID]?.discardRetainedResult()
    }
  }

  private func makeModel(id: String) -> LUTPreviewModel {
    LUTPreviewModel(
      id: id,
      retainedResultDidChange: { [weak self] lutID, cost in
        self?.retainedResultDidChange(for: lutID, cost: cost)
      }
    )
  }
}
