import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(CloudKitSupportMacros)
import CloudKitSupportMacros

let testMacros: [String: Macro.Type] = [
  "CloudKitRecord": CloudKitRecordMacro.self,
  "CKField": CKFieldMacro.self,
]
#endif

final class CloudKitSupportMacrosTests: XCTestCase {
  func testCloudKitRecordMacroExpansion() throws {
    #if canImport(CloudKitSupportMacros)
    assertMacroExpansion(
      """
      @CloudKitRecord(type: "Card")
      final class CardRecord {
        @CKField("kind", .string, required: true)
        var kindRawValue: String

        @CKField("body", .string, default: "")
        var body: String
      }
      """,
      expandedSource: """
      final class CardRecord {
        var kindRawValue: String {
            get {
              CKFieldBridge.get(
                record: record,
                fieldName: "kind",
                valueKind: .string,
                defaultValue: nil,
                isRequired: true
              )
            }
            set {
              CKFieldBridge.set(
                newValue,
                record: record,
                fieldName: "kind",
                valueKind: .string
              )
            }
        }
        var body: String {
            get {
              CKFieldBridge.get(
                record: record,
                fieldName: "body",
                valueKind: .string,
                defaultValue: "",
                isRequired: false
              )
            }
            set {
              CKFieldBridge.set(
                newValue,
                record: record,
                fieldName: "body",
                valueKind: .string
              )
            }
        }

          let record: CKRecord

          static let recordType: String = "Card"

          static let descriptor = CloudKitRecordDescriptor(
            recordType: recordType,
            fields: [
              CloudKitFieldDescriptor(
                "kind",
                valueKind: .string,
                isRequiredForUpload: true,
                missingFieldBehavior: .rejectRecord,
                defaultValueDescription: nil
              ),
              CloudKitFieldDescriptor(
                "body",
                valueKind: .string,
                isRequiredForUpload: false,
                missingFieldBehavior: .defaultValue(String(describing: "")),
                defaultValueDescription: String(describing: "")
              )
            ]
          )

          init(record: CKRecord) {
            self.record = record
          }

          convenience init(recordID: CKRecord.ID) {
            self.init(record: CKRecord(recordType: Self.recordType, recordID: recordID))
          }
      }

      extension CardRecord: CloudKitRecordTransport {
      }
      """,
      macros: testMacros
    )
    #else
    throw XCTSkip("macros are only supported when running tests for the host platform")
    #endif
  }
}
