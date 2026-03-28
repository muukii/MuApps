//
//  BackgroundTaskManager.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2026/01/05.
//

import BackgroundTasks
import Foundation

/// Manager for BGContinuedProcessingTask scheduling and execution with Live Activity support.
/// Provides a simplified interface for scheduling background work with progress reporting.
@MainActor
final class BackgroundTaskManager {

  // MARK: - Types

  /// Configuration for continued processing tasks (Live Activity support).
  struct ContinuedTaskConfiguration: Sendable {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
      self.title = title
      self.subtitle = subtitle
    }
  }

  /// Context provided to background work closures for cancellation checking and progress reporting.
  final class TaskContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _progress: Double = 0
    private var _bgContinuedTask: BGContinuedProcessingTask?

    /// Whether the task has been cancelled (e.g., by system or explicit cancellation).
    var isCancelled: Bool {
      lock.withLock { _isCancelled }
    }

    /// Current progress value (0.0 - 1.0).
    var progress: Double {
      lock.withLock { _progress }
    }

    /// Mark the task as cancelled.
    func cancel() {
      lock.withLock { _isCancelled = true }
    }

    /// Report progress (0.0 - 1.0).
    /// For continued tasks, this also updates the Live Activity progress.
    /// - Parameter value: Progress value between 0.0 and 1.0.
    func reportProgress(_ value: Double) {
      lock.withLock {
        _progress = min(max(value, 0), 1)
        _bgContinuedTask?.progress.completedUnitCount = Int64(_progress * 100)
      }
    }

    /// Update Live Activity title and subtitle.
    /// Only effective for continued processing tasks.
    /// - Parameters:
    ///   - title: The title to display.
    ///   - subtitle: Optional subtitle to display.
    func updateLiveActivity(title: String, subtitle: String = "") {
      lock.withLock {
        _bgContinuedTask?.updateTitle(title, subtitle: subtitle)
      }
    }

    /// Set the BGContinuedProcessingTask reference for Live Activity updates.
    fileprivate func setBGContinuedTask(_ task: BGContinuedProcessingTask?) {
      lock.withLock {
        _bgContinuedTask = task
        // Initialize progress for Live Activity
        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = Int64(_progress * 100)
      }
    }
  }

  /// Pending task information (work closure stored but not yet executed).
  private struct PendingTask {
    let context: TaskContext
    let work: @Sendable (TaskContext) async -> Void
    let configuration: ContinuedTaskConfiguration?
  }

  /// Active task information (work is executing).
  private struct ActiveTask {
    let task: Task<Void, Never>
    let context: TaskContext
    let bgTask: BGTask?  // nil on simulator (BGContinuedProcessingTask not supported)
  }

  // MARK: - Properties

  /// Singleton instance.
  static let shared = BackgroundTaskManager()

  /// Whether running on simulator (BGContinuedProcessingTask not supported).
  private let isSimulator: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }()

  /// Pending tasks by identifier (submitted but not yet launched by system).
  private var pendingTasks: [String: PendingTask] = [:]

  /// Active tasks by identifier (launched by system and executing).
  private var activeTasks: [String: ActiveTask] = [:]

  /// Registered task identifiers.
  private var registeredIdentifiers: Set<String> = []

  // MARK: - Initialization

  private init() {}

  // MARK: - Public Methods

  /// Schedule a continued processing task with Live Activity support.
  /// Work will only start when the system launches the BGTask (showing Live Activity).
  /// On simulator, work executes immediately in foreground (BGContinuedProcessingTask not supported).
  /// - Parameters:
  ///   - identifier: Unique identifier for the task (must be in Info.plist BGTaskSchedulerPermittedIdentifiers).
  ///   - configuration: Configuration for the Live Activity (title, subtitle).
  ///   - work: The async work to perform. Receives a TaskContext for cancellation checking and progress reporting.
  /// - Returns: True if the task was scheduled successfully.
  @discardableResult
  func scheduleContinued(
    identifier: String,
    configuration: ContinuedTaskConfiguration,
    work: @escaping @Sendable (TaskContext) async -> Void
  ) -> Bool {
    // Don't schedule if already pending or running
    guard pendingTasks[identifier] == nil && activeTasks[identifier] == nil else {
      print("[BackgroundTaskManager] Continued task '\(identifier)' is already pending or running")
      return false
    }

    let context = TaskContext()

    // Simulator fallback: BGContinuedProcessingTask is not supported on simulator
    // Execute work immediately in foreground instead
    if isSimulator {
      print("[BackgroundTaskManager] Simulator detected - executing continued task '\(identifier)' in foreground")

      let workTask = Task { [weak self] in
        await work(context)
        await MainActor.run {
          self?.taskCompleted(identifier: identifier)
        }
      }

      activeTasks[identifier] = ActiveTask(
        task: workTask,
        context: context,
        bgTask: nil
      )

      return true
    }

    // Register handler if not already registered
    if !registeredIdentifiers.contains(identifier) {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {
        [weak self] bgTask in
        guard let bgTask = bgTask as? BGContinuedProcessingTask else { return }
        Task { @MainActor in
          self?.handleBGContinuedTask(bgTask, identifier: identifier)
        }
      }
      registeredIdentifiers.insert(identifier)
    }

    // Store as pending task (work will start when BGTask is launched)
    pendingTasks[identifier] = PendingTask(
      context: context,
      work: work,
      configuration: configuration
    )

    // Schedule BGContinuedProcessingTask request
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: configuration.title,
      subtitle: configuration.subtitle ?? ""
    )
    request.strategy = .queue

    do {
      try BGTaskScheduler.shared.submit(request)
      print("[BackgroundTaskManager] Scheduled continued task '\(identifier)'")
      return true
    } catch {
      print("[BackgroundTaskManager] Failed to schedule continued task '\(identifier)': \(error)")
      // Clean up pending task since BGTask submission failed
      pendingTasks.removeValue(forKey: identifier)
      return false
    }
  }

  /// Cancel a pending or running task.
  /// - Parameter identifier: The task identifier.
  func cancel(identifier: String) {
    // Cancel pending task
    if let pendingTask = pendingTasks.removeValue(forKey: identifier) {
      pendingTask.context.cancel()
      print("[BackgroundTaskManager] Cancelled pending task '\(identifier)'")
      return
    }

    // Cancel active task
    if let activeTask = activeTasks.removeValue(forKey: identifier) {
      activeTask.context.cancel()
      activeTask.task.cancel()
      print("[BackgroundTaskManager] Cancelled active task '\(identifier)'")
      return
    }
  }

  /// Check if a task is currently pending or running.
  /// - Parameter identifier: The task identifier.
  /// - Returns: True if the task is pending or running.
  func isRunning(identifier: String) -> Bool {
    pendingTasks[identifier] != nil || activeTasks[identifier] != nil
  }

  /// Get the context for a pending or running task.
  /// - Parameter identifier: The task identifier.
  /// - Returns: The task context, or nil if not found.
  func context(for identifier: String) -> TaskContext? {
    pendingTasks[identifier]?.context ?? activeTasks[identifier]?.context
  }

  // MARK: - Private Methods

  private func handleBGContinuedTask(_ bgTask: BGContinuedProcessingTask, identifier: String) {
    // Get pending task (work hasn't started yet)
    guard let pendingTask = pendingTasks.removeValue(forKey: identifier) else {
      print("[BackgroundTaskManager] No pending task found for '\(identifier)'")
      bgTask.setTaskCompleted(success: false)
      return
    }

    // Set the BGContinuedProcessingTask reference in context for Live Activity updates
    pendingTask.context.setBGContinuedTask(bgTask)

    // Now start the actual work
    let workTask = Task { [weak self] in
      await pendingTask.work(pendingTask.context)
      await MainActor.run {
        self?.taskCompleted(identifier: identifier)
      }
    }

    // Move to active tasks
    activeTasks[identifier] = ActiveTask(
      task: workTask,
      context: pendingTask.context,
      bgTask: bgTask
    )

    // Set expiration handler
    bgTask.expirationHandler = { [weak self] in
      Task { @MainActor in
        self?.activeTasks[identifier]?.context.cancel()
        self?.activeTasks[identifier]?.task.cancel()
      }
    }

    // Monitor completion
    Task {
      await workTask.value
      bgTask.setTaskCompleted(success: !pendingTask.context.isCancelled)
    }

    print("[BackgroundTaskManager] Started continued task '\(identifier)' with Live Activity")
  }

  private func taskCompleted(identifier: String) {
    activeTasks.removeValue(forKey: identifier)
    print("[BackgroundTaskManager] Task '\(identifier)' completed")
  }
}
