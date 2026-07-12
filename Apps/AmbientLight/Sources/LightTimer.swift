import Foundation
import Observation

/// Owns one optional light-session timer and its expiration task.
///
/// The timer is date-based rather than tick-count-based so returning from the
/// background reconciles against real elapsed time instead of extending a session.
@Observable
final class LightTimer {

  /// Durations intentionally kept short enough for relaxation, focus, or bedtime use.
  enum Preset: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60

    var id: Int { rawValue }

    var title: LocalizedStringResource {
      switch self {
      case .fifteenMinutes:
        "15 min"
      case .thirtyMinutes:
        "30 min"
      case .oneHour:
        "1 hour"
      }
    }
  }

  private(set) var endDate: Date?
  private(set) var isExpired = false

  @ObservationIgnored
  private var expirationTask: Task<Void, Never>?

  var isRunning: Bool { endDate != nil && !isExpired }

  func start(_ preset: Preset) {
    let endDate = Date().addingTimeInterval(TimeInterval(preset.rawValue * 60))
    self.endDate = endDate
    isExpired = false
    scheduleExpiration(at: endDate)
  }

  func cancel() {
    expirationTask?.cancel()
    expirationTask = nil
    endDate = nil
    isExpired = false
  }

  func wake() {
    cancel()
  }

  /// Reconciles a suspended app against wall-clock time when it becomes active.
  func reconcile(at date: Date = .now) {
    guard let endDate else { return }

    if endDate <= date {
      expire()
    } else {
      scheduleExpiration(at: endDate)
    }
  }

  private func scheduleExpiration(at endDate: Date) {
    expirationTask?.cancel()
    let remaining = max(0, endDate.timeIntervalSinceNow)

    expirationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        self?.expire()
      } catch {
        // Cancellation is expected whenever the timer is replaced or stopped.
      }
    }
  }

  private func expire() {
    expirationTask?.cancel()
    expirationTask = nil
    endDate = nil
    isExpired = true
  }
}
