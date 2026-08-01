//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import OSLog
import Observation

/// Identifies either the no-LUT result or one concrete LUT preview.
nonisolated enum LUTPreviewItemID: Hashable, Sendable {
  case original
  case lut(String)

  var logValue: String {
    switch self {
    case .original:
      return "original"
    case .lut(let id):
      return id
    }
  }
}

/// Identifies one rendered LUT result for a source frame and library revision.
nonisolated struct LUTPreviewRequestID: Hashable, Sendable {

  /// The source still identity. A new stopped frame produces a new value.
  var sourceID: String
  /// The no-LUT result or stable LUT identity being rendered.
  var itemID: LUTPreviewItemID
  /// Invalidates a result when the LUT bytes change without changing its id.
  var libraryRevision: UInt
  /// Invalidates every look when its shared pre-LUT exposure changes.
  var exposureEV: Double
}

/// The source and library state shared by every LUT model on one screen.
nonisolated struct LUTPreviewContextID: Hashable, Sendable {

  var sourceID: String?
  var libraryRevision: UInt
  var exposureEV: Double = 0
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

  let id: LUTPreviewItemID

  private(set) var renderedImage: CGImage?
  private(set) var phase: Phase = .idle

  private var activeRequestID: LUTPreviewRequestID?
  @ObservationIgnored private var renderTask: Task<Void, Never>?
  @ObservationIgnored private var isVisible = false
  @ObservationIgnored private let retainedResultDidChange:
    @MainActor @Sendable (LUTPreviewItemID, Int) -> Void

  init(
    id: LUTPreviewItemID,
    retainedResultDidChange:
      @escaping @MainActor @Sendable (LUTPreviewItemID, Int) -> Void
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
    recipe: LUTPreviewRecipe?,
    exposure: ExposureAdjustment
  ) {
    isVisible = true
    Self.logger.debug(
      "Appear LUT \(self.id.logValue, privacy: .public), source \(requestID.sourceID, privacy: .public), revision \(requestID.libraryRevision)"
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
        "Start render LUT \(requestID.itemID.logValue, privacy: .public)"
      )
      do {
        let image = try await LUTPreviewRenderer.shared.render(
          source: source,
          recipe: recipe,
          exposure: exposure,
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
          "Finish render LUT \(requestID.itemID.logValue, privacy: .public)"
        )
        self.retainedResultDidChange(
          self.id,
          image.bytesPerRow * image.height
        )
      } catch is CancellationError {
        Self.logger.debug(
          "Cancel render LUT \(requestID.itemID.logValue, privacy: .public)"
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
          "Fail render LUT \(requestID.itemID.logValue, privacy: .public): \(error.localizedDescription)"
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
        "Invalidate LUT \(self.id.logValue, privacy: .public), source \(activeRequestID.sourceID, privacy: .public), revision \(activeRequestID.libraryRevision)"
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
      contextID.libraryRevision == activeRequestID.libraryRevision,
      contextID.exposureEV == activeRequestID.exposureEV
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

/// Persists per-item preview models above lazy cells and bounds strong results.
///
/// Models are cheap and remain keyed by stable preview identity. Their rendered
/// `CGImage`s are pixel-bounded and use a separate cost-limited LRU so a large
/// library cannot retain every rendered result.
@MainActor
@Observable
final class LUTPreviewModelStore {

  @ObservationIgnored private var modelsByID: [LUTPreviewItemID: LUTPreviewModel] = [:]
  @ObservationIgnored private var contextID: LUTPreviewContextID?
  @ObservationIgnored private var retainedCosts: [LUTPreviewItemID: Int] = [:]
  @ObservationIgnored private var retentionOrder: [LUTPreviewItemID] = []
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
  func model(for itemID: LUTPreviewItemID) -> LUTPreviewModel {
    if let model = modelsByID[itemID] {
      return model
    }
    let model = makeModel(id: itemID)
    modelsByID[itemID] = model
    return model
  }

  /// Adds and removes models only when the LUT catalog itself changes.
  func synchronize(lutIDs: [String]) {
    let requestedIDs = Set(lutIDs.map(LUTPreviewItemID.lut)).union([.original])
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
    for itemID: LUTPreviewItemID,
    cost: Int
  ) {
    removeRetainedCost(for: itemID)
    guard cost > 0 else { return }

    retainedCosts[itemID] = cost
    retentionOrder.append(itemID)
    totalRetainedCost += cost
    evictIfNeeded(excluding: itemID)
  }

  private func removeRetainedCost(for itemID: LUTPreviewItemID) {
    if let existingCost = retainedCosts.removeValue(forKey: itemID) {
      totalRetainedCost -= existingCost
    }
    retentionOrder.removeAll { $0 == itemID }
  }

  private func evictIfNeeded(excluding protectedID: LUTPreviewItemID) {
    while totalRetainedCost > retainedCostLimit {
      guard
        let index = retentionOrder.firstIndex(where: { itemID in
          itemID != protectedID
            && modelsByID[itemID]?.canDiscardRetainedResult == true
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

  private func makeModel(id: LUTPreviewItemID) -> LUTPreviewModel {
    LUTPreviewModel(
      id: id,
      retainedResultDidChange: { [weak self] itemID, cost in
        self?.retainedResultDidChange(for: itemID, cost: cost)
      }
    )
  }
}
