import CoreLocation
import Foundation

/// A geographic coordinate attached to a `Card`.
///
/// Stored on `Card` as an optional SwiftData composite attribute (`Codable`).
/// Absence (`nil`) means the card has no location — either the user has not
/// granted location access, or none was available at capture time. A present
/// value therefore always implies the user permitted location use.
public struct Coordinate: Codable, Hashable, Sendable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}

// MARK: - CoreLocation Bridging

extension Coordinate {
  public init(_ coordinate: CLLocationCoordinate2D) {
    self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
  }

  public var clCoordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
