import CloudKit
import CoreLocation
import Foundation

/// A value that knows how to bridge itself to CloudKit's `CLLocation` field
/// representation.
///
/// Domain modules can conform lightweight coordinate values to this protocol
/// without making `CloudKitSupport` depend on those domain types.
public protocol CKLocationValue {
  /// Creates the domain value from a CloudKit location field.
  init(cloudKitLocation: CLLocation)

  /// CloudKit-compatible location field value.
  var cloudKitLocation: CLLocation { get }
}

/// Runtime helpers used by `@CKField` generated accessors.
///
/// `CKFieldBridge` is deliberately small and transport-oriented. It converts
/// between `CKRecord` user-field payloads and wrapper property types, but it
/// does not know about SwiftData models, app state, or sync policy.
public enum CKFieldBridge {
  /// Reads a typed value from a `CKRecord` field.
  public static func get<Value>(
    record: CKRecord,
    fieldName: String,
    valueKind: CKFieldValueKind,
    defaultValue: Value?,
    isRequired: Bool
  ) -> Value {
    guard let rawValue = record[fieldName] else {
      if let defaultValue {
        return defaultValue
      }
      if let nilValue = optionalNilValue(Value.self) {
        return nilValue
      }
      preconditionFailure("Missing required CloudKit field '\(fieldName)'")
    }

    if let converted = convert(rawValue, valueKind: valueKind, to: Value.self) {
      return converted
    }

    preconditionFailure(
      "CloudKit field '\(fieldName)' cannot be read as \(Value.self)"
    )
  }

  /// Writes a typed value into a `CKRecord` field.
  public static func set<Value>(
    _ value: Value,
    record: CKRecord,
    fieldName: String,
    valueKind: CKFieldValueKind
  ) {
    guard let boxedValue = box(value, valueKind: valueKind) else {
      record[fieldName] = nil
      return
    }

    guard let recordValue = boxedValue as? any CKRecordValue else {
      preconditionFailure(
        "CloudKit field '\(fieldName)' cannot store \(type(of: boxedValue))"
      )
    }

    record[fieldName] = recordValue
  }
}

// MARK: - Conversion

extension CKFieldBridge {
  private static func convert<Value>(
    _ rawValue: Any,
    valueKind: CKFieldValueKind,
    to type: Value.Type
  ) -> Value? {
    if let value = rawValue as? Value {
      return value
    }

    if let optionalType = Value.self as? AnyOptional.Type {
      guard
        let wrapped = convertNonOptional(
          rawValue,
          valueKind: valueKind,
          to: optionalType.wrappedType
        )
      else {
        return nil
      }
      return optionalType.some(wrapped) as? Value
    }

    return convertNonOptional(rawValue, valueKind: valueKind, to: type) as? Value
  }

  private static func convertNonOptional(
    _ rawValue: Any,
    valueKind: CKFieldValueKind,
    to type: Any.Type
  ) -> Any? {
    switch valueKind {
    case .location:
      guard
        let location = rawValue as? CLLocation,
        let locationType = type as? any CKLocationValue.Type
      else {
        return rawValue
      }
      return locationType.init(cloudKitLocation: location)
    default:
      return rawValue
    }
  }

  private static func box<Value>(
    _ value: Value,
    valueKind: CKFieldValueKind
  ) -> Any? {
    if let optional = value as? AnyOptional {
      guard let wrappedValue = optional.wrappedValue else {
        return nil
      }
      return boxAny(wrappedValue, valueKind: valueKind)
    }

    return boxAny(value, valueKind: valueKind)
  }

  private static func boxAny(
    _ value: Any,
    valueKind: CKFieldValueKind
  ) -> Any? {
    switch valueKind {
    case .location:
      if let locationValue = value as? any CKLocationValue {
        return locationValue.cloudKitLocation
      }
      return value
    default:
      return value
    }
  }
}

// MARK: - Optional

private protocol AnyOptional {
  static var wrappedType: Any.Type { get }
  static var nilValue: Any { get }
  static func some(_ value: Any) -> Any
  var wrappedValue: Any? { get }
}

extension Optional: AnyOptional {
  static var wrappedType: Any.Type { Wrapped.self }
  static var nilValue: Any { Optional<Wrapped>.none as Any }

  static func some(_ value: Any) -> Any {
    let wrappedValue = value as! Wrapped
    return Optional(wrappedValue) as Any
  }

  var wrappedValue: Any? {
    switch self {
    case .none:
      nil
    case .some(let value):
      value
    }
  }
}

private func optionalNilValue<Value>(_ type: Value.Type) -> Value? {
  guard let optionalType = type as? AnyOptional.Type else {
    return nil
  }
  return optionalType.nilValue as? Value
}
