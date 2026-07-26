//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BackgroundTasks
import FargMotionBlur
import Foundation
import OSLog

/// Queue dependency for admitting one attempt at a bounded render capacity.
///
/// Any predecessor may release the next slot, so capacity greater than one
/// tracks a required completion count rather than pinning the dependency to a
/// fixed subset of earlier attempts.
nonisolated struct VideoRenderAdmissionDependency: Equatable, Sendable {

  let predecessorAttemptIDs: [UUID]
  let requiredCompletionCount: Int

  init(
    predecessorAttemptIDs: [UUID],
    renderCapacity: Int
  ) {
    precondition(renderCapacity > 0)
    self.predecessorAttemptIDs = predecessorAttemptIDs
    requiredCompletionCount = max(
      predecessorAttemptIDs.count - (renderCapacity - 1),
      0
    )
  }

  /// Returns truthful aggregate progress for the completions still needed.
  func snapshot(
    progressByAttemptID: [UUID: Double]
  ) -> (fraction: Double, videosAhead: Int)? {
    guard requiredCompletionCount > 0 else { return nil }
    let progressValues = predecessorAttemptIDs.map {
      min(max(progressByAttemptID[$0] ?? 1, 0), 1)
    }
    let mostAdvanced =
      progressValues
      .sorted(by: >)
      .prefix(requiredCompletionCount)
    let fraction =
      mostAdvanced.reduce(0, +) / Double(requiredCompletionCount)
    let completedCount = progressValues.count { $0 >= 1 }
    return (
      fraction,
      max(requiredCompletionCount - completedCount, 0)
    )
  }
}

/// Decides whether one export can obtain every background resource it needs.
///
/// A default continued-processing task provides CPU and network execution, but
/// it does not grant GPU access. Motion Blur must therefore remain foreground
/// work on devices that do not advertise the optional GPU resource.
nonisolated enum VideoExportBackgroundResourceDecision: Equatable, Sendable {
  /// Submit without an optional system resource requirement.
  case submitWithDefaultResources
  /// Submit only when the system grants background GPU access.
  case submitRequiringGPU
  /// Run in the foreground and explain why leaving Färg is unsafe.
  case foreground(VideoExportBackgroundStartError)

  static func resolve(
    isMotionBlurEnabled: Bool,
    supportedResources: BGContinuedProcessingTaskRequest.Resources
  ) -> Self {
    if supportedResources.contains(.gpu) {
      return .submitRequiringGPU
    }
    if isMotionBlurEnabled {
      return .foreground(.motionBlurRequiresForeground)
    }
    return .submitWithDefaultResources
  }
}

/// Owns one picker-ordered export session while each video receives an
/// independent `BGContinuedProcessingTask`.
///
/// Continued-processing tasks provide system runtime, progress, and individual
/// expiration. Actual encoding concurrency is independently bounded by
/// `VideoRenderResourceGate`, whose production capacity is currently one.
@MainActor
final class BackgroundExportCoordinator {

  /// Permitted wildcard prefix declared in Farg's Info.plist.
  static let taskIdentifierPrefix = "app.muukii.farg.export"

  static let shared = BackgroundExportCoordinator()

  private static let logger = Logger(
    subsystem: "app.muukii.farg",
    category: "BackgroundExport"
  )

  private let jobRunner: VideoExportJobRunner
  private let maximumConcurrentRenders: Int
  private var session: VideoExportSessionModel?
  private var jobsByAttemptID: [UUID: VideoExportJob] = [:]
  private var controlsByAttemptID: [UUID: ExportAttemptControl] = [:]
  private var systemRelaysByAttemptID: [UUID: ContinuedProcessingTaskRelay] = [:]
  private var pendingAttemptIDs: [UUID] = []
  private var scheduledAttemptIDs: Set<UUID> = []
  private var unsettledAttemptOrder: [UUID] = []
  private var admissionDependenciesByAttemptID: [UUID: VideoRenderAdmissionDependency] = [:]
  private var renderProgressByAttemptID: [UUID: Double] = [:]
  private var isCancellingAll = false
  private var manualSaveTasks: [UUID: Task<Void, Never>] = [:]

  init(
    jobRunner: VideoExportJobRunner = VideoExportJobRunner(
      exporter: ParametricVideoExporter(),
      renderGate: .shared,
      saveToPhotos: PhotoLibrarySaver.save
    ),
    maximumConcurrentRenders: Int = VideoRenderResourceGate.productionCapacity
  ) {
    precondition(maximumConcurrentRenders > 0)
    self.jobRunner = jobRunner
    self.maximumConcurrentRenders = maximumConcurrentRenders
  }

  // MARK: - Session

  /// Creates app-owned work and foreground-submits every per-video lease.
  ///
  /// Submission remains inside the initiating foreground action. Actual renders
  /// enter the ordered app scheduler independently of handler delivery.
  @discardableResult
  func start(session: VideoExportSessionModel) -> Bool {
    guard
      self.session == nil,
      isCancellingAll == false,
      session.items.isEmpty == false
    else {
      return false
    }

    self.session = session
    Self.cleanupExportsDirectory(keeping: [])

    for item in session.items {
      startNewAttempt(for: item, in: session)
    }
    scheduleWaitingAttempts()
    return true
  }

  /// Discards only a fully-drained session.
  ///
  /// Active teardown must go through `cancelAllAndWait()` first so preview
  /// reconstruction never overlaps an AVFoundation or Photos operation.
  @discardableResult
  func discardSettledSession(sessionID: UUID) -> Bool {
    guard
      session?.id == sessionID,
      session?.isSettled == true,
      session?.hasManualPhotosSaveInProgress == false,
      jobsByAttemptID.isEmpty,
      controlsByAttemptID.isEmpty,
      systemRelaysByAttemptID.isEmpty,
      pendingAttemptIDs.isEmpty,
      scheduledAttemptIDs.isEmpty,
      unsettledAttemptOrder.isEmpty,
      manualSaveTasks.isEmpty
    else {
      return false
    }
    admissionDependenciesByAttemptID.removeAll()
    renderProgressByAttemptID.removeAll()
    session = nil
    return true
  }

  /// Safety path for a sheet removed by its parent rather than its Done action.
  func cancelAndDiscardCurrentSession() async {
    guard let sessionID = session?.id else { return }
    await cancelAllAndWait()
    _ = discardSettledSession(sessionID: sessionID)
  }

  /// Retries only one failed or cancelled row with a new attempt identity.
  func retry(itemID: VideoClip.ID) {
    guard
      isCancellingAll == false,
      let session,
      let item = session.item(id: itemID),
      item.canRetry
    else {
      return
    }
    startNewAttempt(for: item, in: session)
    scheduleWaitingAttempts()
  }

  // MARK: - Cancellation

  /// Cancels one item and waits for its AVFoundation resources to drain.
  func cancelAndWait(itemID: VideoClip.ID) async {
    guard
      let session,
      let item = session.item(id: itemID),
      let attempt = item.attempt,
      item.isTerminal == false
    else {
      return
    }

    guard let control = controlsByAttemptID[attempt.id] else {
      item.markCancelling(attemptID: attempt.id, origin: .user)
      BGTaskScheduler.shared.cancel(
        taskRequestWithIdentifier: attempt.taskIdentifier
      )
      systemRelaysByAttemptID[attempt.id]?.complete(success: false)
      finishCancelled(
        sessionID: session.id,
        itemID: item.id,
        attemptID: attempt.id,
        path: attempt.path,
        origin: .user
      )
      return
    }

    // Publish cancellation to the worker before changing presentation state,
    // so a concurrent completion cannot commit success in between.
    let cancellationWon = control.requestCancellation(origin: .user)
    if cancellationWon {
      item.markCancelling(attemptID: attempt.id, origin: .user)
      BGTaskScheduler.shared.cancel(
        taskRequestWithIdentifier: attempt.taskIdentifier
      )
    }
    if control.hasAttachedTask {
      await control.wait()
    } else if cancellationWon {
      systemRelaysByAttemptID[attempt.id]?.complete(success: false)
      finishCancelled(
        sessionID: session.id,
        itemID: item.id,
        attemptID: attempt.id,
        path: attempt.path,
        origin: .user
      )
    }
  }

  /// Cancels all nonterminal items before awaiting any one media drain.
  func cancelAllAndWait() async {
    guard let session else { return }
    isCancellingAll = true
    defer {
      isCancellingAll = false
      scheduleWaitingAttempts()
    }

    let attempts = session.items.compactMap {
      item -> (VideoExportItemModel, VideoExportItemModel.Attempt)? in
      guard item.isTerminal == false, let attempt = item.attempt else {
        return nil
      }
      return (item, attempt)
    }

    var runningControls: [ExportAttemptControl] = []
    for (item, attempt) in attempts {
      if let control = controlsByAttemptID[attempt.id] {
        let cancellationWon = control.requestCancellation(origin: .user)
        if cancellationWon {
          item.markCancelling(attemptID: attempt.id, origin: .user)
          BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: attempt.taskIdentifier
          )
        }
        if control.hasAttachedTask {
          runningControls.append(control)
        } else if cancellationWon {
          systemRelaysByAttemptID[attempt.id]?.complete(success: false)
          finishCancelled(
            sessionID: session.id,
            itemID: item.id,
            attemptID: attempt.id,
            path: attempt.path,
            origin: .user
          )
        }
      } else {
        item.markCancelling(attemptID: attempt.id, origin: .user)
        BGTaskScheduler.shared.cancel(
          taskRequestWithIdentifier: attempt.taskIdentifier
        )
        systemRelaysByAttemptID[attempt.id]?.complete(success: false)
        finishCancelled(
          sessionID: session.id,
          itemID: item.id,
          attemptID: attempt.id,
          path: attempt.path,
          origin: .user
        )
      }
    }

    await withTaskGroup(of: Void.self) { group in
      for control in runningControls {
        group.addTask {
          await control.wait()
        }
      }
    }

    let manualSaves = Array(manualSaveTasks.values)
    await withTaskGroup(of: Void.self) { group in
      for task in manualSaves {
        group.addTask {
          await task.value
        }
      }
    }
  }

  // MARK: - Photos recovery

  /// Retries Photos import without rerendering the already-shareable movie.
  func saveToPhotos(itemID: VideoClip.ID) {
    guard
      isCancellingAll == false,
      let session,
      let item = session.item(id: itemID),
      let save = item.beginManualPhotosSave()
    else {
      return
    }

    session.beginManualPhotosSave()
    let task = Task {
      do {
        try await PhotoLibrarySaver.save(videoAt: save.url)
        item.finishManualPhotosSave(
          attemptID: save.attemptID,
          result: .success(())
        )
      } catch {
        item.finishManualPhotosSave(
          attemptID: save.attemptID,
          result: .failure(error)
        )
      }
      session.finishManualPhotosSave()
      manualSaveTasks.removeValue(forKey: save.attemptID)
    }
    manualSaveTasks[save.attemptID] = task
  }

  // MARK: - Attempt submission

  private func startNewAttempt(
    for item: VideoExportItemModel,
    in session: VideoExportSessionModel
  ) {
    let attemptID = UUID()
    let taskIdentifier =
      "\(Self.taskIdentifierPrefix).\(attemptID.uuidString.lowercased())"
    let outputURL = Self.makeOutputURL(
      position: item.position,
      attemptID: attemptID
    )
    guard
      let attempt = item.beginAttempt(
        id: attemptID,
        taskIdentifier: taskIdentifier,
        outputURL: outputURL
      )
    else {
      return
    }
    session.markAttemptStarted(itemID: item.id)

    let job = VideoExportJob(
      sessionID: session.id,
      itemID: item.id,
      attemptID: attempt.id,
      position: item.position,
      displayName: item.displayName,
      source: item.source,
      colorInfo: item.colorInfo,
      recipe: session.recipe,
      outputURL: attempt.outputURL,
      taskIdentifier: attempt.taskIdentifier
    )
    let control = ExportAttemptControl()
    let admissionDependency = VideoRenderAdmissionDependency(
      predecessorAttemptIDs: unsettledAttemptOrder,
      renderCapacity: maximumConcurrentRenders
    )
    let initialDependencySnapshot = admissionDependency.snapshot(
      progressByAttemptID: renderProgressByAttemptID
    )
    let sessionID = job.sessionID
    let itemID = job.itemID
    let jobAttemptID = job.attemptID
    let systemRelay = ContinuedProcessingTaskRelay(
      displayName: job.displayName,
      waitingVideosAhead:
        initialDependencySnapshot?.videosAhead
        ?? admissionDependency.requiredCompletionCount
    ) { [weak self, weak control] in
      guard
        let control,
        control.requestCancellation(origin: .system)
      else {
        return
      }
      Task { @MainActor [weak self] in
        self?.handleSystemCancellation(
          sessionID: sessionID,
          itemID: itemID,
          attemptID: jobAttemptID
        )
      }
    }
    if let initialDependencySnapshot {
      systemRelay.updateWaitingProgress(
        predecessorFraction: initialDependencySnapshot.fraction,
        videosAhead: initialDependencySnapshot.videosAhead
      )
    }

    jobsByAttemptID[attempt.id] = job
    controlsByAttemptID[attempt.id] = control
    systemRelaysByAttemptID[attempt.id] = systemRelay
    admissionDependenciesByAttemptID[attempt.id] = admissionDependency
    renderProgressByAttemptID[attempt.id] = 0
    unsettledAttemptOrder.append(attempt.id)
    pendingAttemptIDs.append(attempt.id)

    let path = submitSystemLease(
      job: job,
      control: control,
      relay: systemRelay
    )
    item.markWaitingForRenderSlot(
      attemptID: attempt.id,
      path: path
    )
    updateWaitingSystemProgress()
  }

  /// Foreground-submits one per-video lease without transferring work ownership.
  ///
  /// The launch handler may attach before or after app-side admission. In both
  /// cases the ordered app scheduler remains the only render-start authority.
  private func submitSystemLease(
    job: VideoExportJob,
    control: ExportAttemptControl,
    relay: ContinuedProcessingTaskRelay
  ) -> VideoExportExecutionPath {
    let resourceDecision =
      VideoExportBackgroundResourceDecision.resolve(
        isMotionBlurEnabled: job.recipe.motionBlur.isEnabled,
        supportedResources: BGTaskScheduler.supportedResources
      )
    let shouldRequestGPU: Bool
    switch resourceDecision {
    case .foreground(let error):
      Self.logger.notice("\(error.localizedDescription, privacy: .public)")
      relay.complete(success: false)
      let path = VideoExportExecutionPath.foreground(error)
      control.setExecutionPath(path)
      return path

    case .submitWithDefaultResources:
      shouldRequestGPU = false
    case .submitRequiringGPU:
      shouldRequestGPU = true
    }

    let didRegister = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: job.taskIdentifier,
      // The handler only attaches a system lease to already-running app work.
      using: .main
    ) { task in
      guard let continuedTask = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      relay.attach(continuedTask)
    }

    guard didRegister else {
      let error =
        VideoExportBackgroundStartError
        .handlerRegistrationFailed(identifier: job.taskIdentifier)
      Self.logger.error("\(error.localizedDescription, privacy: .public)")
      relay.complete(success: false)
      let path = VideoExportExecutionPath.foreground(error)
      control.setExecutionPath(path)
      return path
    }

    let initialPresentation = relay.currentSnapshot()
    let request = BGContinuedProcessingTaskRequest(
      identifier: job.taskIdentifier,
      title: initialPresentation.title,
      subtitle: initialPresentation.subtitle
    )
    request.strategy = .queue
    if shouldRequestGPU {
      request.requiredResources = .gpu
    } else {
      Self.logger.notice(
        "Background GPU is unavailable; submitting \(job.taskIdentifier, privacy: .public) with default resources."
      )
    }

    do {
      try BGTaskScheduler.shared.submit(request)
      let path = VideoExportExecutionPath.background
      control.setExecutionPath(path)
      return path
    } catch {
      let startError = VideoExportBackgroundStartError(
        submissionError: error
      )
      Self.logger.error("\(startError.localizedDescription, privacy: .public)")
      relay.complete(success: false)
      let path = VideoExportExecutionPath.foreground(startError)
      control.setExecutionPath(path)
      return path
    }
  }

  // MARK: - Ordered app scheduler

  private func scheduleWaitingAttempts() {
    guard isCancellingAll == false else { return }

    while scheduledAttemptIDs.count < maximumConcurrentRenders,
      pendingAttemptIDs.isEmpty == false
    {
      let attemptID = pendingAttemptIDs.removeFirst()
      guard
        let job = jobsByAttemptID[attemptID],
        let control = controlsByAttemptID[attemptID],
        let systemRelay = systemRelaysByAttemptID[attemptID],
        control.isCancellationRequested == false,
        canRun(job: job)
      else {
        continue
      }
      scheduledAttemptIDs.insert(attemptID)
      startWork(
        job: job,
        control: control,
        systemRelay: systemRelay
      )
    }
    updateWaitingSystemProgress()
  }

  private func canRun(job: VideoExportJob) -> Bool {
    guard
      session?.id == job.sessionID,
      let item = session?.item(id: job.itemID),
      let attempt = item.attempt,
      attempt.id == job.attemptID,
      case .active = attempt.state
    else {
      return false
    }
    return true
  }

  /// Commits app-side render admission without waiting for handler delivery.
  private func admitRender(
    job: VideoExportJob,
    control: ExportAttemptControl,
    relay: ContinuedProcessingTaskRelay
  ) throws -> VideoExportExecutionPath {
    guard
      control.isCancellationRequested == false,
      let path = control.executionPath,
      canRun(job: job)
    else {
      throw CancellationError()
    }
    relay.beginRendering()
    return path
  }

  // MARK: - Work

  private func startWork(
    job: VideoExportJob,
    control: ExportAttemptControl,
    systemRelay: ContinuedProcessingTaskRelay
  ) {
    guard canRun(job: job) else {
      return
    }

    let progressEmitter = ItemProgressEmitter(
      systemRelay: systemRelay
    ) { [weak self] path, renderFraction in
      Task { @MainActor [weak self] in
        self?.updateRendering(
          job: job,
          path: path,
          fraction: renderFraction
        )
      }
    }
    let runner = jobRunner
    let coordinator = self

    // Handler delivery does not start this app-owned task. The ordered session
    // scheduler starts it, then the process gate arbitrates other entry points.
    let work = Task.detached(priority: .userInitiated) {
      do {
        let outcome = try await runner.run(
          job: job,
          onRenderAdmission: {
            try Task.checkCancellation()
            return try await coordinator.admitRender(
              job: job,
              control: control,
              relay: systemRelay
            )
          },
          onPhase: { phase, path in
            if case .savingToPhotos = phase {
              progressEmitter.markSavingToPhotos()
            }
            await coordinator.updatePhase(
              phase,
              job: job,
              path: path
            )
          },
          onRenderProgress: { path, fraction in
            progressEmitter.update(
              path: path,
              renderFraction: fraction
            )
          }
        )
        if let origin = control.resolveCompletion() {
          Self.removeFile(job.outputURL)
          await coordinator.finishCancelled(
            sessionID: job.sessionID,
            itemID: job.itemID,
            attemptID: job.attemptID,
            path: outcome.path,
            origin: origin
          )
          systemRelay.complete(success: false)
        } else {
          progressEmitter.complete()
          let didFinish = await coordinator.finishExported(
            job: job,
            path: outcome.path,
            photos: outcome.photos
          )
          systemRelay.complete(success: didFinish)
        }
      } catch is CancellationError {
        Self.removeFile(job.outputURL)
        let origin =
          control.resolveCompletion(
            defaultCancellationOrigin: .system
          ) ?? .system
        await coordinator.finishCancelled(
          sessionID: job.sessionID,
          itemID: job.itemID,
          attemptID: job.attemptID,
          path: control.executionPath,
          origin: origin
        )
        systemRelay.complete(success: false)
      } catch {
        Self.removeFile(job.outputURL)
        if let origin = control.resolveCompletion() {
          await coordinator.finishCancelled(
            sessionID: job.sessionID,
            itemID: job.itemID,
            attemptID: job.attemptID,
            path: control.executionPath,
            origin: origin
          )
        } else {
          await coordinator.finishFailed(
            job: job,
            path: control.executionPath,
            message: error.localizedDescription
          )
        }
        systemRelay.complete(success: false)
      }
    }
    control.attach(work)
  }

  private func updatePhase(
    _ phase: VideoExportJobRunner.Phase,
    job: VideoExportJob,
    path: VideoExportExecutionPath
  ) {
    guard
      session?.id == job.sessionID,
      let item = session?.item(id: job.itemID),
      let attempt = item.attempt,
      attempt.id == job.attemptID
    else {
      return
    }

    switch phase {
    case .rendering:
      guard case .active(.waitingForRenderSlot) = attempt.state else {
        return
      }
      renderProgressByAttemptID[job.attemptID] = 0
      item.markRendering(
        attemptID: job.attemptID,
        path: path,
        fraction: 0
      )
      updateWaitingSystemProgress()
    case .savingToPhotos:
      renderProgressByAttemptID[job.attemptID] = 1
      item.markSavingToPhotos(
        attemptID: job.attemptID,
        path: path
      )
      releaseScheduledAttempt(job.attemptID)
    }
  }

  private func updateRendering(
    job: VideoExportJob,
    path: VideoExportExecutionPath,
    fraction: Double
  ) {
    guard
      session?.id == job.sessionID,
      let item = session?.item(id: job.itemID),
      let attempt = item.attempt,
      attempt.id == job.attemptID,
      case .active(.rendering) = attempt.state
    else {
      return
    }
    let fraction = min(max(fraction, 0), 1)
    renderProgressByAttemptID[job.attemptID] = max(
      renderProgressByAttemptID[job.attemptID] ?? 0,
      fraction
    )
    item.markRendering(
      attemptID: job.attemptID,
      path: path,
      fraction: fraction
    )
    updateWaitingSystemProgress()
  }

  private func releaseScheduledAttempt(_ attemptID: UUID) {
    guard scheduledAttemptIDs.remove(attemptID) != nil else { return }
    renderProgressByAttemptID[attemptID] = 1
    scheduleWaitingAttempts()
  }

  /// Reports the real predecessor work that must advance before each queued
  /// video can enter the app's render scheduler.
  private func updateWaitingSystemProgress() {
    for (attemptID, dependency) in admissionDependenciesByAttemptID {
      guard
        let relay = systemRelaysByAttemptID[attemptID],
        let job = jobsByAttemptID[attemptID],
        let item = session?.item(id: job.itemID),
        let attempt = item.attempt,
        attempt.id == attemptID,
        case .active(.waitingForRenderSlot) = attempt.state,
        let dependencySnapshot = dependency.snapshot(
          progressByAttemptID: renderProgressByAttemptID
        )
      else {
        continue
      }

      relay.updateWaitingProgress(
        predecessorFraction: dependencySnapshot.fraction,
        videosAhead: dependencySnapshot.videosAhead
      )
    }
  }

  private func handleSystemCancellation(
    sessionID: UUID,
    itemID: VideoClip.ID,
    attemptID: UUID
  ) {
    guard
      let session,
      session.id == sessionID,
      let item = session.item(id: itemID),
      let attempt = item.attempt,
      attempt.id == attemptID,
      item.isTerminal == false,
      let control = controlsByAttemptID[attemptID]
    else {
      return
    }

    item.markCancelling(attemptID: attemptID, origin: .system)
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: attempt.taskIdentifier
    )
    guard control.hasAttachedTask == false else { return }

    systemRelaysByAttemptID[attemptID]?.complete(success: false)
    finishCancelled(
      sessionID: sessionID,
      itemID: itemID,
      attemptID: attemptID,
      path: control.executionPath,
      origin: .system
    )
  }

  private func finishExported(
    job: VideoExportJob,
    path: VideoExportExecutionPath,
    photos: VideoExportItemModel.Attempt.PhotosState
  ) -> Bool {
    guard
      let session,
      session.id == job.sessionID,
      let item = session.item(id: job.itemID)
    else {
      Self.removeFile(job.outputURL)
      clearAttempt(job.attemptID)
      return false
    }
    let didFinish = item.finish(
      attemptID: job.attemptID,
      with: .exported(
        path: path,
        url: job.outputURL,
        photos: photos
      )
    )
    if didFinish {
      session.markAttemptFinished(itemID: job.itemID)
    } else {
      Self.removeFile(job.outputURL)
    }
    clearAttempt(job.attemptID)
    return didFinish
  }

  private func finishFailed(
    job: VideoExportJob,
    path: VideoExportExecutionPath?,
    message: String
  ) {
    guard
      let session,
      session.id == job.sessionID,
      let item = session.item(id: job.itemID)
    else {
      clearAttempt(job.attemptID)
      return
    }
    let didFinish = item.finish(
      attemptID: job.attemptID,
      with: .failed(path: path, message: message)
    )
    if didFinish {
      session.markAttemptFinished(itemID: job.itemID)
    }
    clearAttempt(job.attemptID)
  }

  private func finishCancelled(
    sessionID: UUID,
    itemID: VideoClip.ID,
    attemptID: UUID,
    path: VideoExportExecutionPath?,
    origin: VideoExportCancellationOrigin
  ) {
    Self.removeFile(
      jobsByAttemptID[attemptID]?.outputURL
    )
    guard
      let session,
      session.id == sessionID,
      let item = session.item(id: itemID)
    else {
      clearAttempt(attemptID)
      return
    }
    let didFinish = item.finish(
      attemptID: attemptID,
      with: .cancelled(path: path, origin: origin)
    )
    if didFinish {
      session.markAttemptFinished(itemID: itemID)
    }
    clearAttempt(attemptID)
  }

  private func clearAttempt(_ attemptID: UUID) {
    if let taskIdentifier = jobsByAttemptID[attemptID]?.taskIdentifier {
      // App-owned work can finish before the system delivers its handler.
      // Remove an unlaunched request; a racing late handler still reaches the
      // relay captured by its registration and is completed immediately.
      BGTaskScheduler.shared.cancel(
        taskRequestWithIdentifier: taskIdentifier
      )
    }
    renderProgressByAttemptID[attemptID] = 1
    pendingAttemptIDs.removeAll { $0 == attemptID }
    scheduledAttemptIDs.remove(attemptID)
    unsettledAttemptOrder.removeAll { $0 == attemptID }
    admissionDependenciesByAttemptID.removeValue(forKey: attemptID)
    systemRelaysByAttemptID.removeValue(forKey: attemptID)
    jobsByAttemptID.removeValue(forKey: attemptID)
    controlsByAttemptID.removeValue(forKey: attemptID)
    scheduleWaitingAttempts()
  }

  // MARK: - Output storage

  private nonisolated static func cachesExportsDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Exports", isDirectory: true)
  }

  private nonisolated static func makeOutputURL(
    position: Int,
    attemptID: UUID
  ) -> URL {
    let directory = cachesExportsDirectory()
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appendingPathComponent(
      "Färg-\(position)-\(attemptID.uuidString).mov"
    )
  }

  /// Removes files from prior dismissed sessions while preserving this one.
  private nonisolated static func cleanupExportsDirectory(
    keeping keepURLs: Set<URL>
  ) {
    let directory = cachesExportsDirectory()
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    for file in files where keepURLs.contains(file) == false {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private nonisolated static func removeFile(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

/// Immutable input for one video export attempt.
nonisolated struct VideoExportJob: Sendable {
  let sessionID: UUID
  let itemID: VideoClip.ID
  let attemptID: UUID
  let position: Int
  let displayName: String
  let source: VideoSource
  let colorInfo: VideoColorInfo
  let recipe: FargVideoRenderRecipe
  let outputURL: URL
  let taskIdentifier: String
}

/// Runs exactly one video through encoding and automatic Photos import.
///
/// The render permit is released before Photos work begins, allowing a future
/// policy with multiple jobs to overlap lightweight import with the next
/// resource-heavy encode.
nonisolated struct VideoExportJobRunner: Sendable {

  /// Result of an admitted render and its subsequent Photos import.
  struct Outcome: Sendable {
    let path: VideoExportExecutionPath
    let photos: VideoExportItemModel.Attempt.PhotosState
  }

  enum Phase: Sendable {
    case rendering
    case savingToPhotos
  }

  typealias PhotoSaver = @Sendable (URL) async throws -> Void

  let exporter: any VideoExporting
  let renderGate: VideoRenderResourceGate
  let saveToPhotos: PhotoSaver

  func run(
    job: VideoExportJob,
    onRenderAdmission:
      @escaping @Sendable () async throws -> VideoExportExecutionPath,
    onPhase:
      @escaping @Sendable (Phase, VideoExportExecutionPath) async -> Void,
    onRenderProgress:
      @escaping @Sendable (VideoExportExecutionPath, Double) -> Void
  ) async throws -> Outcome {
    let path = try await renderGate.withPermit {
      try Task.checkCancellation()
      let path = try await onRenderAdmission()
      try Task.checkCancellation()
      await onPhase(.rendering, path)
      try Task.checkCancellation()
      try await exporter.export(
        asset: job.source.asset,
        recipe: job.recipe,
        colorInfo: job.colorInfo,
        to: job.outputURL,
        onProgress: { fraction in
          onRenderProgress(path, fraction)
        }
      )
      return path
    }

    try Task.checkCancellation()
    await onPhase(.savingToPhotos, path)
    try Task.checkCancellation()

    do {
      try await saveToPhotos(job.outputURL)
      try Task.checkCancellation()
      return Outcome(path: path, photos: .saved)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return Outcome(
        path: path,
        photos: .readyToSave(message: error.localizedDescription)
      )
    }
  }
}

/// Sticky cancellation shared by app controls and a system expiration handler.
///
/// Expiration can race task creation. `attach(_:)` observes an earlier request
/// and immediately cancels the newly-created work, so no attempt escapes its
/// system lease.
nonisolated final class ExportAttemptControl: @unchecked Sendable {

  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancellationDrain: Task<Void, Never>?
  private var origin: VideoExportCancellationOrigin?
  private var path: VideoExportExecutionPath?
  private var didResolveCompletion = false

  var hasAttachedTask: Bool {
    lock.withLock { task != nil }
  }

  var cancellationOrigin: VideoExportCancellationOrigin? {
    lock.withLock { origin }
  }

  var isCancellationRequested: Bool {
    lock.withLock { origin != nil }
  }

  var executionPath: VideoExportExecutionPath? {
    lock.withLock { path }
  }

  func setExecutionPath(_ newPath: VideoExportExecutionPath) {
    lock.withLock {
      if path == nil {
        path = newPath
      }
    }
  }

  func attach(_ newTask: Task<Void, Never>) {
    lock.withLock {
      task = newTask
      if origin != nil, cancellationDrain == nil {
        cancellationDrain = Self.makeCancellationDrain(for: newTask)
      }
    }
  }

  @discardableResult
  func requestCancellation(
    origin newOrigin: VideoExportCancellationOrigin
  ) -> Bool {
    lock.withLock {
      guard didResolveCompletion == false, origin == nil else {
        return false
      }
      origin = newOrigin
      if let task, cancellationDrain == nil {
        cancellationDrain = Self.makeCancellationDrain(for: task)
      }
      return true
    }
  }

  /// Atomically decides whether cancellation or ordinary completion won.
  func resolveCompletion(
    defaultCancellationOrigin: VideoExportCancellationOrigin? = nil
  ) -> VideoExportCancellationOrigin? {
    lock.withLock {
      if origin == nil {
        origin = defaultCancellationOrigin
      }
      didResolveCompletion = true
      return origin
    }
  }

  func wait() async {
    let current = lock.withLock { cancellationDrain ?? task }
    await current?.value
  }

  /// Runs synchronous media cancellation away from MainActor, then waits for
  /// both its cancellation handler and the worker to release their resources.
  private static func makeCancellationDrain(
    for task: Task<Void, Never>
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      task.cancel()
      await task.value
    }
  }
}

/// Coalesces sample callbacks to whole-percent app UI updates while keeping
/// scheduler-visible background progress fine-grained.
private nonisolated final class ItemProgressEmitter: @unchecked Sendable {

  private let lock = NSLock()
  private let systemRelay: ContinuedProcessingTaskRelay
  private let onVisibleProgress: @Sendable (VideoExportExecutionPath, Double) -> Void
  private var lastVisiblePercent = -1

  init(
    systemRelay: ContinuedProcessingTaskRelay,
    onVisibleProgress:
      @escaping @Sendable (VideoExportExecutionPath, Double) -> Void
  ) {
    self.systemRelay = systemRelay
    self.onVisibleProgress = onVisibleProgress
  }

  func update(
    path: VideoExportExecutionPath,
    renderFraction: Double
  ) {
    let fraction = min(max(renderFraction, 0), 1)
    systemRelay.updateRenderingProgress(fraction)
    let percent = Int(fraction * 100)

    let shouldEmit = lock.withLock {
      guard percent > lastVisiblePercent else { return false }
      lastVisiblePercent = percent
      return true
    }
    if shouldEmit {
      onVisibleProgress(path, fraction)
    }
  }

  func markSavingToPhotos() {
    systemRelay.markSavingToPhotos()
  }

  func complete() {
    systemRelay.markWorkCompleted()
  }
}

/// Immutable progress and copy shown by one continued-processing task.
nonisolated struct ContinuedProcessingTaskProgressSnapshot:
  Equatable, Sendable
{

  let fraction: Double
  let title: String
  let subtitle: String
}

/// Bridges independently-started app work to a possibly late system handler.
///
/// Registration closures retain this small relay rather than media jobs. It
/// caches progress until a handler arrives, forwards expiration to the attempt
/// control, and immediately resolves a handler delivered after work settled.
///
/// The first 5% describes real scheduler admission: predecessor renders must
/// advance before a queued item can start. Its own render occupies 5–99%, and
/// Photos import occupies the final 1%.
nonisolated final class ContinuedProcessingTaskRelay:
  @unchecked Sendable
{

  private static let renderStartFraction = 0.05
  private static let photosStartFraction = 0.99

  private let lock = NSLock()
  private let displayName: String
  private var onExpiration: (@Sendable () -> Void)?
  private var taskHandle: ContinuedProcessingTaskHandle?
  private var latestSnapshot: ContinuedProcessingTaskProgressSnapshot
  private var renderBaseFraction: Double?
  private var completion: Bool?

  init(
    displayName: String,
    waitingVideosAhead: Int,
    onExpiration: @escaping @Sendable () -> Void
  ) {
    self.displayName = displayName
    latestSnapshot = Self.waitingSnapshot(
      displayName: displayName,
      fraction: 0,
      videosAhead: waitingVideosAhead
    )
    self.onExpiration = onExpiration
  }

  func attach(_ task: BGContinuedProcessingTask) {
    let handle = ContinuedProcessingTaskHandle(task)
    let state:
      (
        didAttach: Bool,
        completion: Bool?,
        snapshot: ContinuedProcessingTaskProgressSnapshot,
        onExpiration: (@Sendable () -> Void)?
      ) = lock.withLock {
        guard completion == nil else {
          return (false, completion, latestSnapshot, nil)
        }
        guard taskHandle == nil else {
          return (false, false, latestSnapshot, nil)
        }
        taskHandle = handle
        return (true, nil, latestSnapshot, onExpiration)
      }

    if state.didAttach {
      if let onExpiration = state.onExpiration {
        handle.setExpirationHandler(onExpiration)
      }
      handle.update(state.snapshot)
    } else {
      handle.update(state.snapshot)
      handle.complete(success: state.completion ?? false)
    }
  }

  /// Supplies truthful waiting copy before a system handler is attached.
  func currentSnapshot() -> ContinuedProcessingTaskProgressSnapshot {
    lock.withLock { latestSnapshot }
  }

  /// Advances only while actual predecessor renders make progress.
  func updateWaitingProgress(
    predecessorFraction: Double,
    videosAhead: Int
  ) {
    let queueFraction =
      min(max(predecessorFraction, 0), 1)
      * Self.renderStartFraction
    updateWhileActive { current in
      guard renderBaseFraction == nil else { return nil }
      return Self.waitingSnapshot(
        displayName: displayName,
        fraction: max(current.fraction, queueFraction),
        videosAhead: videosAhead
      )
    }
  }

  /// Marks the app scheduler's real admission point for this render.
  func beginRendering() {
    updateWhileActive { current in
      guard renderBaseFraction == nil else { return nil }
      let base = max(current.fraction, Self.renderStartFraction)
      renderBaseFraction = base
      return Self.renderingSnapshot(
        displayName: displayName,
        fraction: base,
        renderFraction: 0
      )
    }
  }

  func updateRenderingProgress(_ renderFraction: Double) {
    let renderFraction = min(max(renderFraction, 0), 1)
    updateWhileActive { current in
      let base =
        renderBaseFraction
        ?? max(current.fraction, Self.renderStartFraction)
      renderBaseFraction = base
      let overallFraction =
        base
        + renderFraction * (Self.photosStartFraction - base)
      return Self.renderingSnapshot(
        displayName: displayName,
        fraction: max(current.fraction, overallFraction),
        renderFraction: renderFraction
      )
    }
  }

  func markSavingToPhotos() {
    updateWhileActive { current in
      ContinuedProcessingTaskProgressSnapshot(
        fraction: max(current.fraction, Self.photosStartFraction),
        title: Self.exportingTitle(displayName: displayName),
        subtitle: String(localized: "Saving to Photos…")
      )
    }
  }

  func markWorkCompleted() {
    updateWhileActive { _ in
      Self.completedSnapshot(displayName: displayName)
    }
  }

  @discardableResult
  func complete(success: Bool) -> Bool {
    let resolution:
      (
        handle: ContinuedProcessingTaskHandle?,
        snapshot: ContinuedProcessingTaskProgressSnapshot
      )? = lock.withLock {
        guard completion == nil else { return nil }
        completion = success
        if success {
          latestSnapshot = Self.completedSnapshot(
            displayName: displayName
          )
        }
        onExpiration = nil
        defer { taskHandle = nil }
        return (taskHandle, latestSnapshot)
      }
    guard let resolution else { return false }
    resolution.handle?.update(resolution.snapshot)
    resolution.handle?.complete(success: success)
    return true
  }

  private func updateWhileActive(
    _ transform:
      (
        ContinuedProcessingTaskProgressSnapshot
      ) -> ContinuedProcessingTaskProgressSnapshot?
  ) {
    let update:
      (
        handle: ContinuedProcessingTaskHandle?,
        snapshot: ContinuedProcessingTaskProgressSnapshot
      )? = lock.withLock {
        guard
          completion == nil,
          let next = transform(latestSnapshot),
          next.fraction >= latestSnapshot.fraction,
          next != latestSnapshot
        else {
          return nil
        }
        latestSnapshot = next
        return (taskHandle, next)
      }
    if let update {
      update.handle?.update(update.snapshot)
    }
  }

  private static func waitingSnapshot(
    displayName: String,
    fraction: Double,
    videosAhead: Int
  ) -> ContinuedProcessingTaskProgressSnapshot {
    let subtitle: String
    switch videosAhead {
    case ...0:
      subtitle = String(localized: "Waiting for render slot…")
    case 1:
      subtitle = String(localized: "Waiting for 1 earlier video…")
    default:
      subtitle = String(
        localized: "Waiting for \(videosAhead) earlier videos…",
        comment:
          "Queued export subtitle. The variable is the count of earlier videos."
      )
    }
    return ContinuedProcessingTaskProgressSnapshot(
      fraction: min(max(fraction, 0), Self.renderStartFraction),
      title: String(
        localized: "Waiting to export \(displayName)",
        comment:
          "System queued-export title. The variable is the video's display name."
      ),
      subtitle: subtitle
    )
  }

  private static func renderingSnapshot(
    displayName: String,
    fraction: Double,
    renderFraction: Double
  ) -> ContinuedProcessingTaskProgressSnapshot {
    let percent = Int(min(max(renderFraction, 0), 1) * 100)
    return ContinuedProcessingTaskProgressSnapshot(
      fraction: min(max(fraction, 0), Self.photosStartFraction),
      title: exportingTitle(displayName: displayName),
      subtitle: String(
        localized: "\(percent)% complete",
        comment:
          "System export progress subtitle. The variable is the render's whole-number percentage."
      )
    )
  }

  private static func completedSnapshot(
    displayName: String
  ) -> ContinuedProcessingTaskProgressSnapshot {
    ContinuedProcessingTaskProgressSnapshot(
      fraction: 1,
      title: exportingTitle(displayName: displayName),
      subtitle: String(localized: "Complete")
    )
  }

  private static func exportingTitle(displayName: String) -> String {
    String(
      localized: "Exporting \(displayName)",
      comment:
        "System export progress title. The variable is the video's display name."
    )
  }
}

/// Lock-confined adapter around the non-Sendable BackgroundTasks object.
private nonisolated final class ContinuedProcessingTaskHandle:
  @unchecked Sendable
{

  private static let progressUnitCount: Int64 = 10_000

  private let lock = NSLock()
  private let task: BGContinuedProcessingTask
  private var lastCompletedUnit: Int64 = -1
  private var lastTitle: String?
  private var lastSubtitle: String?
  private var didComplete = false

  init(_ task: BGContinuedProcessingTask) {
    self.task = task
    task.progress.totalUnitCount = Self.progressUnitCount
  }

  func update(_ snapshot: ContinuedProcessingTaskProgressSnapshot) {
    let fraction = min(max(snapshot.fraction, 0), 1)
    let completedUnit = Int64(
      fraction * Double(Self.progressUnitCount)
    )

    lock.withLock {
      guard didComplete == false else { return }
      if completedUnit > lastCompletedUnit {
        lastCompletedUnit = completedUnit
        task.progress.completedUnitCount = completedUnit
      }
      if snapshot.title != lastTitle
        || snapshot.subtitle != lastSubtitle
      {
        lastTitle = snapshot.title
        lastSubtitle = snapshot.subtitle
        task.updateTitle(
          snapshot.title,
          subtitle: snapshot.subtitle
        )
      }
    }
  }

  func complete(success: Bool) {
    lock.withLock {
      guard didComplete == false else { return }
      didComplete = true
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
    }
  }

  func setExpirationHandler(
    _ handler: @escaping @Sendable () -> Void
  ) {
    lock.withLock {
      guard didComplete == false else { return }
      task.expirationHandler = handler
    }
  }
}
