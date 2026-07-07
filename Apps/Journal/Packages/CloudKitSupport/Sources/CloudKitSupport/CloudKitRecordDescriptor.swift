import CloudKit
import Foundation

/// Code-owned description of one CloudKit record type.
///
/// A descriptor is not a live CloudKit Console schema export. It is the app's
/// source-readable contract for the record type names, field keys, value kinds,
/// import tolerance, and domain relationships expected by generated wrappers.
public struct CloudKitRecordDescriptor: Sendable, Hashable {
  /// CloudKit record type name.
  public var recordType: String

  /// User fields written under this record type.
  public var fields: [CloudKitFieldDescriptor]

  /// Relationship-like links represented by ordinary fields or CloudKit
  /// system relationships.
  public var relationships: [CloudKitRelationshipDescriptor]

  /// Human-facing notes about migration risk or domain constraints.
  public var notes: [String]

  public init(
    recordType: String,
    fields: [CloudKitFieldDescriptor],
    relationships: [CloudKitRelationshipDescriptor] = [],
    notes: [String] = []
  ) {
    self.recordType = recordType
    self.fields = fields
    self.relationships = relationships
    self.notes = notes
  }

  /// Finds a field descriptor by CloudKit user-field key.
  public func field(named name: String) -> CloudKitFieldDescriptor? {
    fields.first { $0.name == name }
  }
}

/// Storage shape for a relationship-like CloudKit link.
public enum CloudKitRelationshipStorage: Sendable, Hashable {
  /// A record-name UUID string stored in a user field.
  case recordNameString(fieldName: String)

  /// An optional record-name UUID string stored in a user field.
  case optionalRecordNameString(fieldName: String)

  /// CloudKit's built-in parent relationship.
  case recordParent

  /// A `CKRecord.Reference` user field.
  case recordReference(fieldName: String)
}

/// Relationship-like link between CloudKit record types.
public struct CloudKitRelationshipDescriptor: Sendable, Hashable {
  /// Source record type containing the relationship storage.
  public var sourceRecordType: String

  /// Target record type referenced by the source.
  public var targetRecordType: String

  /// How the relationship is represented in CloudKit.
  public var storage: CloudKitRelationshipStorage

  /// Whether the relationship is required for a valid local row.
  public var isRequired: Bool

  /// Human-facing domain notes for constraints CloudKit cannot enforce.
  public var notes: [String]

  public init(
    sourceRecordType: String,
    targetRecordType: String,
    storage: CloudKitRelationshipStorage,
    isRequired: Bool,
    notes: [String] = []
  ) {
    self.sourceRecordType = sourceRecordType
    self.targetRecordType = targetRecordType
    self.storage = storage
    self.isRequired = isRequired
    self.notes = notes
  }
}

/// Class-based CloudKit transport wrapper.
///
/// Conforming types own a `CKRecord` directly and should stay inside the sync
/// boundary. They are not domain models and should not cross into SwiftData or
/// SwiftUI layers.
public protocol CloudKitRecordTransport: AnyObject {
  /// CloudKit record type name.
  static var recordType: String { get }

  /// Descriptor synthesized from `@CKField` declarations.
  static var descriptor: CloudKitRecordDescriptor { get }

  /// The wrapped CloudKit record.
  var record: CKRecord { get }

  /// Wraps an existing fetched record.
  init(record: CKRecord)

  /// Creates a new record shell with this wrapper's record type.
  init(recordID: CKRecord.ID)
}
