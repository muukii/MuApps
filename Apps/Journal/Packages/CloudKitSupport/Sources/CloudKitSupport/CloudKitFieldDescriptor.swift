import Foundation

/// CloudKit value category expected for one `CKRecord` field.
///
/// This is intentionally smaller than CloudKit's full runtime type surface.
/// It captures the schema contract a generated record wrapper wants to expose,
/// while generated accessors still perform concrete Swift conversions.
public enum CKFieldValueKind: String, Sendable, Hashable {
  case string
  case date
  case int
  case double
  case bool
  case data
  case location
  case asset
}

public typealias CloudKitFieldValueKind = CKFieldValueKind

/// How an importer should treat a missing field when reading an existing
/// CloudKit record.
///
/// Required upload fields may still be tolerant on import so older or partially
/// repaired records do not make the whole vault unreadable.
public enum CloudKitMissingFieldBehavior: Sendable, Hashable {
  /// Leave the existing local value unchanged.
  case preserveExistingValue

  /// Replace the local value with `nil`.
  case clearValue

  /// Use the described local fallback value.
  case defaultValue(String)

  /// Skip or reject the imported record because the field is structurally
  /// required to create a valid local row.
  case rejectRecord
}

/// Index expectation for a CloudKit field.
///
/// This does not inspect the deployed CloudKit Console schema. It documents the
/// app-side expectation so reviews and release checklists can compare code
/// intent with Development/Production containers.
public enum CloudKitFieldIndexExpectation: Sendable, Hashable {
  /// No server-side query or sort requirement is currently expected.
  case none

  /// The field is expected to be queryable.
  case queryable

  /// The field is expected to be sortable, and therefore also queryable.
  case sortable
}

/// Code-owned description of one field in a CloudKit record type.
public struct CloudKitFieldDescriptor: Sendable, Hashable {
  /// Field key used in `CKRecord` user fields.
  public var name: String

  /// Expected CloudKit-compatible value category.
  public var valueKind: CKFieldValueKind

  /// Whether outgoing records should always provide this field.
  public var isRequiredForUpload: Bool

  /// Import behavior when the field is absent from a fetched record.
  public var missingFieldBehavior: CloudKitMissingFieldBehavior

  /// Source-level description of a macro default expression, if present.
  public var defaultValueDescription: String?

  /// Server-side index expectation owned by app code.
  public var indexExpectation: CloudKitFieldIndexExpectation

  /// Human-facing schema notes: migration risk, domain meaning, or constraints
  /// that CloudKit itself cannot enforce.
  public var notes: [String]

  public init(
    _ name: String,
    valueKind: CKFieldValueKind,
    isRequiredForUpload: Bool,
    missingFieldBehavior: CloudKitMissingFieldBehavior,
    defaultValueDescription: String? = nil,
    indexExpectation: CloudKitFieldIndexExpectation = .none,
    notes: [String] = []
  ) {
    self.name = name
    self.valueKind = valueKind
    self.isRequiredForUpload = isRequiredForUpload
    self.missingFieldBehavior = missingFieldBehavior
    self.defaultValueDescription = defaultValueDescription
    self.indexExpectation = indexExpectation
    self.notes = notes
  }
}
