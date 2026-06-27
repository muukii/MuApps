import CoreLocation
import JournalModel
import Observation

/// Bridges Core Location into the card-creation flow, where the only question is:
/// *where am I right now, if I'm allowed to know?*
///
/// The journal attaches a location to a card only when the user opts in **per
/// card** (the location toggle in `CreationView`). So this owns exactly two
/// things — the permission prompt and a single one-shot fix — and deliberately
/// nothing more: no continuous tracking, no background updates. A journal needs
/// the spot you were standing when you wrote, not a trail.
///
/// `authorizationStatus` is observed so the UI reflects the live system state;
/// the permission prompt is fired lazily when the user reaches for location, so
/// nothing is asked for until it's wanted.
@MainActor
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {

  /// The current Core Location authorization. Mirrors the system value and is
  /// updated by the delegate when the user answers the permission prompt.
  private(set) var authorizationStatus: CLAuthorizationStatus

  /// Whether a coordinate can be obtained right now without prompting.
  var isAuthorized: Bool {
    Self.isAuthorized(authorizationStatus)
  }

  private let manager = CLLocationManager()

  /// The in-flight one-shot fix, if any. Only one hardware request runs at a
  /// time; a newer request supersedes an older pending one.
  private var pendingFix: CheckedContinuation<Coordinate?, Never>?

  /// Authorization waiters created when coordinate capture starts before the
  /// user has answered the system prompt.
  private var pendingAuthorizationRequests: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

  override init() {
    self.authorizationStatus = manager.authorizationStatus
    super.init()
    manager.delegate = self
    // Neighborhood-level accuracy: enough to remember *where* a card was written,
    // and it returns a fix faster and cheaper than a precise GPS lock.
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// Prompts for When-In-Use access if the user hasn't decided yet. A no-op once
  /// the choice is made — the result arrives via the delegate, which updates
  /// `authorizationStatus`.
  func requestAuthorization() {
    guard authorizationStatus == .notDetermined else { return }
    manager.requestWhenInUseAuthorization()
  }

  /// Resolves the device's current coordinate, or `nil` when location is denied
  /// or a fix can't be obtained. If permission has not been requested yet, this
  /// method asks first and then continues only when the user grants access.
  func requestCoordinate() async -> Coordinate? {
    let authorizationStatus = await requestAuthorizationStatusIfNeeded()
    guard Self.isAuthorized(authorizationStatus) else { return nil }

    // A new request supersedes any stale one — finish the previous continuation
    // so it can never leak unresumed.
    resumePendingFix(with: nil)

    return await withCheckedContinuation { continuation in
      pendingFix = continuation
      manager.requestLocation()
    }
  }

  private func requestAuthorizationStatusIfNeeded() async -> CLAuthorizationStatus {
    guard authorizationStatus == .notDetermined else {
      return authorizationStatus
    }

    return await withCheckedContinuation { continuation in
      pendingAuthorizationRequests.append(continuation)
      manager.requestWhenInUseAuthorization()
    }
  }

  private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      return true
    case .notDetermined, .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func resumePendingAuthorizationRequests(with status: CLAuthorizationStatus) {
    guard status != .notDetermined else { return }

    let continuations = pendingAuthorizationRequests
    pendingAuthorizationRequests.removeAll()
    for continuation in continuations {
      continuation.resume(returning: status)
    }
  }

  private func resumePendingFix(with coordinate: Coordinate?) {
    guard let continuation = pendingFix else { return }
    pendingFix = nil
    continuation.resume(returning: coordinate)
  }

  // MARK: - CLLocationManagerDelegate

  // Core Location delivers these on the queue the manager was created on — the
  // main actor here — so hopping back with `assumeIsolated` is safe.

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let authorizationStatus = manager.authorizationStatus
    MainActor.assumeIsolated {
      self.authorizationStatus = authorizationStatus
      resumePendingAuthorizationRequests(with: authorizationStatus)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    let coordinate = locations.last.map { Coordinate($0.coordinate) }
    MainActor.assumeIsolated {
      resumePendingFix(with: coordinate)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: any Swift.Error
  ) {
    MainActor.assumeIsolated {
      resumePendingFix(with: nil)
    }
  }
}
