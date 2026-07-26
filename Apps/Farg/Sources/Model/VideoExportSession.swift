//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import Foundation
import Observation

/// One immutable source movie in the picker-ordered export session.
nonisolated struct VideoExportSessionItem: Identifiable, Sendable {

  let id: VideoClip.ID
  let displayName: String
  /// Keeps Files authorization alive through detached/background rendering.
  let source: VideoSource
  let colorInfo: VideoColorInfo

  var asset: AVAsset { source.asset }
}

/// Why a video attempt could not use continued processing.
nonisolated enum VideoExportBackgroundStartError: LocalizedError, Equatable, Sendable {

  /// The concrete dynamic identifier was not covered by the app's permitted
  /// wildcard, so `BGTaskScheduler` rejected handler registration.
  case handlerRegistrationFailed(identifier: String)

  /// `BGTaskScheduler` rejected the continued-processing request.
  case requestSubmissionFailed(
    description: String,
    domain: String,
    code: Int
  )

  var errorDescription: String? {
    switch self {
    case .handlerRegistrationFailed(let identifier):
      return String(
        localized:
          "The system could not register background export \(identifier).",
        comment:
          "Background export registration error. The variable is the task identifier."
      )

    case .requestSubmissionFailed(let description, let domain, let code):
      return String(
        localized:
          "The system rejected the background export request: \(description) (\(domain), code \(code)).",
        comment:
          "Background export scheduling error. The variables are the system error description, domain, and numeric code."
      )
    }
  }

  init(submissionError: any Error) {
    let error = submissionError as NSError
    self = .requestSubmissionFailed(
      description: error.localizedDescription,
      domain: error.domain,
      code: error.code
    )
  }
}

/// Where one concrete video attempt is executing.
nonisolated enum VideoExportExecutionPath: Equatable, Sendable {
  /// A per-video continued-processing request was accepted by the system.
  case background
  /// Running without a continued-processing lease because setup failed.
  case foreground(VideoExportBackgroundStartError)
}

/// The source that requested cancellation of one export attempt.
nonisolated enum VideoExportCancellationOrigin: Equatable, Sendable {
  case user
  case system
}

/// Stable presentation and state ownership for one picker item.
///
/// The model's identity never changes. A retry replaces only its nested
/// `Attempt`, allowing late callbacks from an older attempt to be rejected
/// without removing or reinserting the SwiftUI row.
@MainActor
@Observable
final class VideoExportItemModel: Identifiable {

  /// One execution generation for this row.
  nonisolated struct Attempt: Identifiable, Equatable, Sendable {

    /// State that is valid only while work may still advance.
    enum Active: Equatable, Sendable {
      /// The user action is registering and submitting the per-video lease.
      case preparingBackgroundRequest
      /// App-owned work is waiting for admission to the render resource.
      case waitingForRenderSlot(path: VideoExportExecutionPath)
      case rendering(path: VideoExportExecutionPath, fraction: Double)
      case savingToPhotos(path: VideoExportExecutionPath)

      var path: VideoExportExecutionPath? {
        switch self {
        case .preparingBackgroundRequest:
          return nil
        case .waitingForRenderSlot(let path),
          .rendering(let path, _),
          .savingToPhotos(let path):
          return path
        }
      }

      var progressFraction: Double {
        switch self {
        case .preparingBackgroundRequest, .waitingForRenderSlot:
          return 0
        case .rendering(_, let fraction):
          return min(max(fraction, 0), 1) * 0.99
        case .savingToPhotos:
          return 0.99
        }
      }
    }

    /// Photos import remains independently recoverable after rendering.
    enum PhotosState: Equatable, Sendable {
      case saved
      case readyToSave(message: String?)
      case saving
    }

    /// Durable outcome of one attempt.
    enum Finish: Equatable, Sendable {
      case exported(
        path: VideoExportExecutionPath,
        url: URL,
        photos: PhotosState
      )
      case failed(path: VideoExportExecutionPath?, message: String)
      case cancelled(
        path: VideoExportExecutionPath?,
        origin: VideoExportCancellationOrigin
      )

      var path: VideoExportExecutionPath? {
        switch self {
        case .exported(let path, _, _):
          return path
        case .failed(let path, _), .cancelled(let path, _):
          return path
        }
      }
    }

    /// Legal lifecycle combinations for one attempt.
    enum State: Equatable, Sendable {
      case active(Active)
      case cancelling(
        lastActive: Active,
        origin: VideoExportCancellationOrigin
      )
      case finished(Finish)
    }

    let id: UUID
    let number: Int
    let taskIdentifier: String
    let outputURL: URL
    var state: State

    var progressFraction: Double {
      switch state {
      case .active(let active):
        return active.progressFraction
      case .cancelling(let active, _):
        return active.progressFraction
      case .finished:
        return 1
      }
    }

    var path: VideoExportExecutionPath? {
      switch state {
      case .active(let active):
        return active.path
      case .cancelling(let active, _):
        return active.path
      case .finished(let finish):
        return finish.path
      }
    }
  }

  /// Whether this row has never started or owns a concrete attempt generation.
  enum State: Equatable {
    case queued
    case attempting(Attempt)
  }

  let id: VideoClip.ID
  let position: Int
  let displayName: String
  let source: VideoSource
  let colorInfo: VideoColorInfo

  private(set) var state: State = .queued

  init(item: VideoExportSessionItem, position: Int) {
    self.id = item.id
    self.position = position
    self.displayName = item.displayName
    self.source = item.source
    self.colorInfo = item.colorInfo
  }

  var isTerminal: Bool {
    guard case .attempting(let attempt) = state else { return false }
    guard case .finished = attempt.state else { return false }
    return true
  }

  var isActive: Bool {
    isTerminal == false
  }

  var progressFraction: Double {
    switch state {
    case .queued:
      return 0
    case .attempting(let attempt):
      return attempt.progressFraction
    }
  }

  var attempt: Attempt? {
    guard case .attempting(let attempt) = state else { return nil }
    return attempt
  }

  var finish: Attempt.Finish? {
    guard
      let attempt,
      case .finished(let finish) = attempt.state
    else {
      return nil
    }
    return finish
  }

  var canRetry: Bool {
    guard let finish else { return false }
    switch finish {
    case .failed, .cancelled:
      return true
    case .exported:
      return false
    }
  }

  /// Replaces a queued or retryable generation while preserving row identity.
  @discardableResult
  func beginAttempt(
    id: UUID,
    taskIdentifier: String,
    outputURL: URL
  ) -> Attempt? {
    switch state {
    case .queued:
      break
    case .attempting where canRetry:
      break
    case .attempting:
      return nil
    }
    let number = (attempt?.number ?? 0) + 1
    let attempt = Attempt(
      id: id,
      number: number,
      taskIdentifier: taskIdentifier,
      outputURL: outputURL,
      state: .active(.preparingBackgroundRequest)
    )
    state = .attempting(attempt)
    return attempt
  }

  /// Records the system path before app-side render admission.
  func markWaitingForRenderSlot(
    attemptID: UUID,
    path: VideoExportExecutionPath
  ) {
    updateActive(attemptID: attemptID) { active in
      guard case .preparingBackgroundRequest = active else { return nil }
      return .waitingForRenderSlot(path: path)
    }
  }

  func markRendering(
    attemptID: UUID,
    path: VideoExportExecutionPath,
    fraction: Double
  ) {
    let fraction = min(max(fraction, 0), 1)
    updateActive(attemptID: attemptID) { active in
      switch active {
      case .waitingForRenderSlot(let currentPath) where currentPath == path:
        return .rendering(path: path, fraction: fraction)
      case .rendering(let currentPath, let currentFraction)
      where currentPath == path && fraction >= currentFraction:
        return .rendering(path: path, fraction: fraction)
      case .preparingBackgroundRequest, .waitingForRenderSlot, .rendering,
        .savingToPhotos:
        return nil
      }
    }
  }

  func markSavingToPhotos(
    attemptID: UUID,
    path: VideoExportExecutionPath
  ) {
    updateActive(attemptID: attemptID) { active in
      switch active {
      case .rendering(let currentPath, _) where currentPath == path:
        return .savingToPhotos(path: path)
      case .waitingForRenderSlot, .preparingBackgroundRequest, .rendering,
        .savingToPhotos:
        return nil
      }
    }
  }

  func markCancelling(
    attemptID: UUID,
    origin: VideoExportCancellationOrigin
  ) {
    guard
      case .attempting(var attempt) = state,
      attempt.id == attemptID,
      case .active(let active) = attempt.state
    else {
      return
    }
    attempt.state = .cancelling(lastActive: active, origin: origin)
    state = .attempting(attempt)
  }

  @discardableResult
  func finish(
    attemptID: UUID,
    with finish: Attempt.Finish
  ) -> Bool {
    guard
      case .attempting(var attempt) = state,
      attempt.id == attemptID
    else {
      return false
    }

    let canFinish: Bool
    switch (attempt.state, finish) {
    case (.active, .exported), (.active, .failed),
      (.active, .cancelled), (.cancelling, .cancelled):
      canFinish = true
    case (.cancelling, .exported), (.cancelling, .failed),
      (.finished, _):
      canFinish = false
    }

    if canFinish {
      attempt.state = .finished(finish)
      state = .attempting(attempt)
      return true
    }
    return false
  }

  /// Moves an exported movie into manual Photos recovery and returns its URL.
  func beginManualPhotosSave() -> (attemptID: UUID, url: URL)? {
    guard
      case .attempting(var attempt) = state,
      case .finished(
        .exported(let path, let url, let photos)
      ) = attempt.state,
      case .readyToSave = photos
    else {
      return nil
    }
    attempt.state = .finished(
      .exported(path: path, url: url, photos: .saving)
    )
    state = .attempting(attempt)
    return (attempt.id, url)
  }

  func finishManualPhotosSave(
    attemptID: UUID,
    result: Result<Void, any Error>
  ) {
    guard
      case .attempting(var attempt) = state,
      attempt.id == attemptID,
      case .finished(
        .exported(let path, let url, .saving)
      ) = attempt.state
    else {
      return
    }

    let photos: Attempt.PhotosState
    switch result {
    case .success:
      photos = .saved
    case .failure(let error):
      photos = .readyToSave(message: error.localizedDescription)
    }
    attempt.state = .finished(
      .exported(path: path, url: url, photos: photos)
    )
    state = .attempting(attempt)
  }

  private func updateActive(
    attemptID: UUID,
    transform: (Attempt.Active) -> Attempt.Active?
  ) {
    guard
      case .attempting(var attempt) = state,
      attempt.id == attemptID,
      case .active(let active) = attempt.state,
      let newActive = transform(active)
    else {
      return
    }
    attempt.state = .active(newActive)
    state = .attempting(attempt)
  }
}

/// Picker-ordered state for one user-initiated export session.
///
/// The `items` collection is immutable after construction. Each row model owns
/// its own observation boundary, so progress from one video does not replace
/// sibling values or change list identity.
@MainActor
@Observable
final class VideoExportSessionModel: Identifiable {

  let id: UUID
  let items: [VideoExportItemModel]
  let recipe: FargVideoRenderRecipe
  private(set) var activeItemIDs: Set<VideoClip.ID>
  private(set) var manualPhotosSaveCount = 0

  init(
    id: UUID = UUID(),
    items: [VideoExportSessionItem],
    recipe: FargVideoRenderRecipe
  ) {
    let itemModels = items.enumerated().map { index, item in
      VideoExportItemModel(item: item, position: index + 1)
    }
    self.id = id
    self.items = itemModels
    self.recipe = recipe
    self.activeItemIDs = Set(itemModels.map(\.id))
  }

  var hdrVideoCount: Int {
    items.count { $0.colorInfo.isHDR }
  }

  var isSettled: Bool {
    items.isEmpty == false && activeItemIDs.isEmpty
  }

  var hasActiveItems: Bool {
    activeItemIDs.isEmpty == false
  }

  var hasManualPhotosSaveInProgress: Bool {
    manualPhotosSaveCount > 0
  }

  var settledCount: Int {
    items.count - activeItemIDs.count
  }

  var exportedCount: Int {
    items.count { item in
      guard let finish = item.finish else { return false }
      guard case .exported = finish else { return false }
      return true
    }
  }

  var failedCount: Int {
    items.count { item in
      guard let finish = item.finish else { return false }
      guard case .failed = finish else { return false }
      return true
    }
  }

  var cancelledCount: Int {
    items.count { item in
      guard let finish = item.finish else { return false }
      guard case .cancelled = finish else { return false }
      return true
    }
  }

  var foregroundFallbackCount: Int {
    items.count { item in
      guard let attempt = item.attempt else { return false }
      guard case .foreground = attempt.path else { return false }
      return item.isTerminal == false
    }
  }

  var overallFraction: Double {
    guard items.isEmpty == false else { return 0 }
    let total = items.reduce(0) { $0 + $1.progressFraction }
    return min(max(total / Double(items.count), 0), 1)
  }

  func item(id: VideoClip.ID) -> VideoExportItemModel? {
    items.first { $0.id == id }
  }

  /// Marks a queued or retried row as active without changing item order.
  func markAttemptStarted(itemID: VideoClip.ID) {
    activeItemIDs.insert(itemID)
  }

  /// Updates session lifecycle only after the matching row commits terminal state.
  func markAttemptFinished(itemID: VideoClip.ID) {
    activeItemIDs.remove(itemID)
  }

  func beginManualPhotosSave() {
    manualPhotosSaveCount += 1
  }

  func finishManualPhotosSave() {
    manualPhotosSaveCount = max(manualPhotosSaveCount - 1, 0)
  }
}
