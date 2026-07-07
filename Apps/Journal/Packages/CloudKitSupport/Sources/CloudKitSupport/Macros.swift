/// Generates a class-based CloudKit transport wrapper around an owned
/// `CKRecord`.
///
/// Apply this only to `final class` declarations. Generated members include
/// the owned `record`, `recordType`, `descriptor`, `init(record:)`, and
/// `init(recordID:)`. The generated extension conforms the class to
/// `CloudKitRecordTransport`.
@attached(member, names: named(record), named(recordType), named(descriptor), named(init(record:)), named(init(recordID:)))
@attached(extension, conformances: CloudKitRecordTransport)
public macro CloudKitRecord(type: StaticString) = #externalMacro(
  module: "CloudKitSupportMacros",
  type: "CloudKitRecordMacro"
)

/// Generates a computed property that bridges through the owning wrapper's
/// `CKRecord` subscript.
@attached(accessor, names: named(get), named(set))
public macro CKField(
  _ name: StaticString,
  _ valueKind: CKFieldValueKind,
  required: Bool = false
) = #externalMacro(
  module: "CloudKitSupportMacros",
  type: "CKFieldMacro"
)

/// Generates a computed property that bridges through the owning wrapper's
/// `CKRecord` subscript and returns the provided value when the field is absent.
@attached(accessor, names: named(get), named(set))
public macro CKField<Value>(
  _ name: StaticString,
  _ valueKind: CKFieldValueKind,
  default defaultValue: Value
) = #externalMacro(
  module: "CloudKitSupportMacros",
  type: "CKFieldMacro"
)
