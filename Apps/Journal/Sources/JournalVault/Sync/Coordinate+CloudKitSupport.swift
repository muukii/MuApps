import CloudKitSupport
import CoreLocation
import Foundation

extension Coordinate: CKLocationValue {
  public init(cloudKitLocation: CLLocation) {
    self.init(cloudKitLocation.coordinate)
  }

  public var cloudKitLocation: CLLocation {
    CLLocation(latitude: latitude, longitude: longitude)
  }
}
