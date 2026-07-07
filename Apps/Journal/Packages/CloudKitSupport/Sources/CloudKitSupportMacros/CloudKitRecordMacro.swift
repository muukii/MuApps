import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct CloudKitRecordMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let recordType = parseRecordType(from: node) ?? "\"\""
    let fields = declaration.memberBlock.members.compactMap { member -> Field? in
      guard
        let variable = member.decl.as(VariableDeclSyntax.self),
        let binding = variable.bindings.first,
        binding.pattern.as(IdentifierPatternSyntax.self) != nil,
        let attribute = ckFieldAttribute(from: variable)
      else {
        return nil
      }
      return parseField(from: attribute)
    }

    let fieldDescriptors = fields
      .map(\.descriptorSource)
      .joined(separator: ",\n")

    return [
      """
      let record: CKRecord
      """,
      """
      static let recordType: String = \(raw: recordType)
      """,
      """
      static let descriptor = CloudKitRecordDescriptor(
        recordType: recordType,
        fields: [
      \(raw: indent(fieldDescriptors, by: 4))
        ]
      )
      """,
      """
      init(record: CKRecord) {
        self.record = record
      }
      """,
      """
      convenience init(recordID: CKRecord.ID) {
        self.init(record: CKRecord(recordType: Self.recordType, recordID: recordID))
      }
      """,
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    [
      try ExtensionDeclSyntax(
        "extension \(type.trimmed): CloudKitRecordTransport {}"
      )
    ]
  }
}

public struct CKFieldMacro: AccessorMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let field = parseField(from: node) else {
      return []
    }

    return [
      """
      get {
        CKFieldBridge.get(
          record: record,
          fieldName: \(raw: field.nameExpression),
          valueKind: \(raw: field.valueKindExpression),
          defaultValue: \(raw: field.defaultExpression ?? "nil"),
          isRequired: \(raw: field.requiredExpression)
        )
      }
      """,
      """
      set {
        CKFieldBridge.set(
          newValue,
          record: record,
          fieldName: \(raw: field.nameExpression),
          valueKind: \(raw: field.valueKindExpression)
        )
      }
      """,
    ]
  }
}

@main
struct CloudKitSupportPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    CloudKitRecordMacro.self,
    CKFieldMacro.self,
  ]
}

// MARK: - Parsing

private struct Field {
  var nameExpression: String
  var valueKindExpression: String
  var requiredExpression: String
  var defaultExpression: String?

  var descriptorSource: String {
    """
    CloudKitFieldDescriptor(
      \(nameExpression),
      valueKind: \(valueKindExpression),
      isRequiredForUpload: \(requiredExpression),
      missingFieldBehavior: \(missingFieldBehaviorSource),
      defaultValueDescription: \(defaultValueDescriptionSource)
    )
    """
  }

  private var missingFieldBehaviorSource: String {
    if let defaultExpression {
      ".defaultValue(String(describing: \(defaultExpression)))"
    } else if requiredExpression == "true" {
      ".rejectRecord"
    } else {
      ".clearValue"
    }
  }

  private var defaultValueDescriptionSource: String {
    if let defaultExpression {
      "String(describing: \(defaultExpression))"
    } else {
      "nil"
    }
  }
}

private func parseRecordType(from node: AttributeSyntax) -> String? {
  node.arguments?
    .as(LabeledExprListSyntax.self)?
    .first?
    .expression
    .trimmed
    .description
}

private func ckFieldAttribute(from variable: VariableDeclSyntax) -> AttributeSyntax? {
  variable.attributes.compactMap { element -> AttributeSyntax? in
    guard case .attribute(let attribute) = element else {
      return nil
    }
    let name = attribute.attributeName.trimmed.description
    return name == "CKField" || name.hasSuffix(".CKField") ? attribute : nil
  }.first
}

private func parseField(from attribute: AttributeSyntax) -> Field? {
  guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
    return nil
  }

  let positional = arguments.filter { $0.label == nil }
  guard positional.count >= 2 else {
    return nil
  }

  let nameExpression = positional[positional.startIndex].expression.trimmed.description
  let valueKindIndex = positional.index(after: positional.startIndex)
  let valueKindExpression = positional[valueKindIndex].expression.trimmed.description
  let requiredExpression = arguments
    .first { $0.label?.text == "required" }?
    .expression
    .trimmed
    .description ?? "false"
  let defaultExpression = arguments
    .first { $0.label?.text == "default" }?
    .expression
    .trimmed
    .description

  return Field(
    nameExpression: nameExpression,
    valueKindExpression: valueKindExpression,
    requiredExpression: defaultExpression == nil ? requiredExpression : "false",
    defaultExpression: defaultExpression
  )
}

private func indent(_ text: String, by spaces: Int) -> String {
  guard !text.isEmpty else { return text }
  let prefix = String(repeating: " ", count: spaces)
  return text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { prefix + $0 }
    .joined(separator: "\n")
}
