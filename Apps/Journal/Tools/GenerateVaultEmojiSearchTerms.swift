import Foundation

/// A fully-qualified row from Unicode's `emoji-test.txt` source.
private struct EmojiRecord {

  let value: String
  let name: String
  let group: String
  let subgroup: String
}

/// One picker family after skin-tone variants have been collapsed.
private struct EmojiFamily {

  let id: String
  let baseRecord: EmojiRecord
  let records: [EmojiRecord]
}

private enum GeneratorError: Error, CustomStringConvertible {

  case invalidArguments
  case missingAnnotation(locale: String, emoji: String, expectedTerm: String)
  case missingBaseRecord(String)
  case unexpectedCount(label: String, expected: Int, actual: Int)

  var description: String {
    switch self {
    case .invalidArguments:
      "Usage: GenerateVaultEmojiSearchTerms.swift <emoji-test.txt> <en-annotations.xml> <en-annotations-derived.xml> <ja-annotations.xml> <ja-annotations-derived.xml> <output.swift>"
    case .missingAnnotation(let locale, let emoji, let expectedTerm):
      "The \(locale) CLDR inputs do not contain \(expectedTerm) for \(emoji)."
    case .missingBaseRecord(let familyID):
      "Could not find a neutral base record for family \(familyID)."
    case .unexpectedCount(let label, let expected, let actual):
      "Unexpected \(label) count. Expected \(expected), got \(actual)."
    }
  }
}

private let skinToneRange: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF

/// Mixed-tone forms whose Unicode sequence differs from the legacy neutral emoji.
private let canonicalFamilyKeyAliases: [String: String] = [
  "\u{1FAF1}\u{200D}\u{1FAF2}": "\u{1F91D}",
  "\u{1F9D1}\u{200D}\u{1F430}\u{200D}\u{1F9D1}": "\u{1F46F}",
  "\u{1F468}\u{200D}\u{1F430}\u{200D}\u{1F468}": "\u{1F46F}\u{200D}\u{2642}",
  "\u{1F469}\u{200D}\u{1F430}\u{200D}\u{1F469}": "\u{1F46F}\u{200D}\u{2640}",
  "\u{1F9D1}\u{200D}\u{1FAEF}\u{200D}\u{1F9D1}": "\u{1F93C}",
  "\u{1F468}\u{200D}\u{1FAEF}\u{200D}\u{1F468}": "\u{1F93C}\u{200D}\u{2642}",
  "\u{1F469}\u{200D}\u{1FAEF}\u{200D}\u{1F469}": "\u{1F93C}\u{200D}\u{2640}",
  "\u{1F469}\u{200D}\u{1F91D}\u{200D}\u{1F469}": "\u{1F46D}",
  "\u{1F469}\u{200D}\u{1F91D}\u{200D}\u{1F468}": "\u{1F46B}",
  "\u{1F468}\u{200D}\u{1F91D}\u{200D}\u{1F468}": "\u{1F46C}",
  "\u{1F9D1}\u{200D}\u{2764}\u{200D}\u{1F48B}\u{200D}\u{1F9D1}": "\u{1F48F}",
  "\u{1F9D1}\u{200D}\u{2764}\u{200D}\u{1F9D1}": "\u{1F491}",
]

private func parseEmojiTest(at url: URL) throws -> [EmojiRecord] {
  let source = try String(contentsOf: url, encoding: .utf8)
  var group = ""
  var subgroup = ""
  var records: [EmojiRecord] = []

  for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = String(rawLine)

    if line.hasPrefix("# group: ") {
      group = String(line.dropFirst("# group: ".count))
      continue
    }

    if line.hasPrefix("# subgroup: ") {
      subgroup = String(line.dropFirst("# subgroup: ".count))
      continue
    }

    guard line.contains("; fully-qualified"),
          let commentStart = line.firstIndex(of: "#") else {
      continue
    }

    let comment = line[line.index(after: commentStart)...]
      .trimmingCharacters(in: .whitespaces)
    let fields = comment.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count == 3 else { continue }

    records.append(
      EmojiRecord(
        value: String(fields[0]),
        name: String(fields[2]),
        group: group,
        subgroup: subgroup.replacingOccurrences(of: "-", with: " ")
      )
    )
  }

  return records
}

private func parseAnnotations(at urls: [URL]) throws -> [String: [String]] {
  var termsByEmoji: [String: [String]] = [:]

  for url in urls {
    let document = try XMLDocument(contentsOf: url, options: [])
    for case let element as XMLElement in try document.nodes(forXPath: "//annotation") {
      guard let emoji = element.attribute(forName: "cp")?.stringValue,
            let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false else {
        continue
      }

      termsByEmoji[annotationKey(for: emoji), default: []].append(
        value.replacingOccurrences(of: " | ", with: " ")
      )
    }
  }

  return termsByEmoji
}

/// Verifies that both the base and skin-tone-derived CLDR data were supplied for a locale.
private func validateAnnotations(
  _ termsByEmoji: [String: [String]],
  locale: String,
  sentinels: [(emoji: String, term: String)]
) throws {
  for sentinel in sentinels {
    let terms = termsByEmoji[annotationKey(for: sentinel.emoji)] ?? []
    guard terms.contains(where: { $0.contains(sentinel.term) }) else {
      throw GeneratorError.missingAnnotation(
        locale: locale,
        emoji: sentinel.emoji,
        expectedTerm: sentinel.term
      )
    }
  }
}

private func annotationKey(for value: String) -> String {
  String(
    value.unicodeScalars.filter { scalar in
      scalar.value != 0xFE0E && scalar.value != 0xFE0F
    }
  )
}

private func makeFamilies(from records: [EmojiRecord]) throws -> [EmojiFamily] {
  var orderedIDs: [String] = []
  var recordsByID: [String: [EmojiRecord]] = [:]

  for record in records {
    let id = familyID(for: record.value)
    if recordsByID[id] == nil {
      orderedIDs.append(id)
    }
    recordsByID[id, default: []].append(record)
  }

  return try orderedIDs.map { id in
    guard let familyRecords = recordsByID[id],
          let baseRecord = familyRecords.first(where: { containsSkinToneModifier($0.value) == false }) else {
      throw GeneratorError.missingBaseRecord(id)
    }
    return EmojiFamily(id: id, baseRecord: baseRecord, records: familyRecords)
  }
}

private func familyID(for value: String) -> String {
  let normalizedKey = String(
    value.unicodeScalars.filter { scalar in
      skinToneRange.contains(scalar.value) == false && scalar.value != 0xFE0F
    }
  )
  return canonicalFamilyKeyAliases[normalizedKey] ?? normalizedKey
}

private func containsSkinToneModifier(_ value: String) -> Bool {
  value.unicodeScalars.contains { skinToneRange.contains($0.value) }
}

private func makeSearchTerms(
  for family: EmojiFamily,
  annotationTermsByEmoji: [String: [String]]
) -> String {
  var terms = family.records.map(\.value)
  terms.append(contentsOf: [
    family.baseRecord.name,
    family.baseRecord.group,
    family.baseRecord.subgroup,
  ])
  for record in family.records {
    terms.append(
      contentsOf: annotationTermsByEmoji[annotationKey(for: record.value)] ?? []
    )
  }

  var seen: Set<String> = []
  let deduplicatedTerms = terms
    .flatMap { term in
      term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    .filter { seen.insert($0).inserted }
    .joined(separator: " ")
  return normalizeSearchText(deduplicatedTerms)
}

private func normalizeSearchText(_ value: String) -> String {
  let folded = value.folding(
    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
    locale: Locale(identifier: "en_US_POSIX")
  )
  let kanaNormalized = folded.applyingTransform(.hiraganaToKatakana, reverse: false)
    ?? folded
  return kanaNormalized
    .replacingOccurrences(of: ".", with: " ")
    .replacingOccurrences(of: "-", with: " ")
    .replacingOccurrences(of: "_", with: " ")
}

private func swiftUnicodeLiteral(_ value: String) -> String {
  value.unicodeScalars
    .map { "\\u{\(String($0.value, radix: 16, uppercase: true))}" }
    .joined()
}

private func swiftStringLiteral(_ value: String) -> String {
  "\"" + value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

private func renderSource(
  families: [EmojiFamily],
  annotationTermsByEmoji: [String: [String]]
) -> String {
  var lines = [
    "// Generated from Unicode Emoji 17.0 and CLDR 48.2.",
    "// Sources:",
    "// - https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
    "// - https://github.com/unicode-org/cldr/blob/release-48-2/common/annotations/en.xml",
    "// - https://github.com/unicode-org/cldr/blob/release-48-2/common/annotations/ja.xml",
    "// - https://github.com/unicode-org/cldr/blob/release-48-2/common/annotationsDerived/en.xml",
    "// - https://github.com/unicode-org/cldr/blob/release-48-2/common/annotationsDerived/ja.xml",
    "// Unicode data license: https://www.unicode.org/license.txt",
    "// Regenerate with Apps/Journal/Tools/GenerateVaultEmojiSearchTerms.swift.",
    "",
    "import Foundation",
    "",
    "/// Generated semantic search terms keyed by `VaultEmojiCatalog.Family.id`.",
    "enum VaultEmojiSearchTerms {",
    "",
    "  static let byFamilyID: [String: String] = [",
  ]

  for family in families {
    let id = swiftUnicodeLiteral(family.id)
    let terms = swiftStringLiteral(
      makeSearchTerms(for: family, annotationTermsByEmoji: annotationTermsByEmoji)
    )
    lines.append("    \"\(id)\": \(terms),")
  }

  lines.append(contentsOf: [
    "  ]",
    "}",
    "",
  ])
  return lines.joined(separator: "\n")
}

do {
  guard CommandLine.arguments.count == 7 else {
    throw GeneratorError.invalidArguments
  }

  let emojiTestURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let englishAnnotationURLs = [
    URL(fileURLWithPath: CommandLine.arguments[2]),
    URL(fileURLWithPath: CommandLine.arguments[3]),
  ]
  let japaneseAnnotationURLs = [
    URL(fileURLWithPath: CommandLine.arguments[4]),
    URL(fileURLWithPath: CommandLine.arguments[5]),
  ]
  let outputURL = URL(fileURLWithPath: CommandLine.arguments[6])

  let records = try parseEmojiTest(at: emojiTestURL)
  let families = try makeFamilies(from: records)
  let englishAnnotationTerms = try parseAnnotations(at: englishAnnotationURLs)
  let japaneseAnnotationTerms = try parseAnnotations(at: japaneseAnnotationURLs)
  try validateAnnotations(
    englishAnnotationTerms,
    locale: "English",
    sentinels: [("🍎", "apple"), ("👊🏿", "dark skin tone")]
  )
  try validateAnnotations(
    japaneseAnnotationTerms,
    locale: "Japanese",
    sentinels: [("🍎", "りんご"), ("👊🏿", "濃い肌色")]
  )
  var annotationTerms = englishAnnotationTerms
  for (emoji, terms) in japaneseAnnotationTerms {
    annotationTerms[emoji, default: []].append(contentsOf: terms)
  }

  guard records.count == 3_944 else {
    throw GeneratorError.unexpectedCount(
      label: "fully-qualified emoji",
      expected: 3_944,
      actual: records.count
    )
  }
  guard families.count == 1_914 else {
    throw GeneratorError.unexpectedCount(
      label: "emoji family",
      expected: 1_914,
      actual: families.count
    )
  }

  try renderSource(families: families, annotationTermsByEmoji: annotationTerms)
    .write(to: outputURL, atomically: true, encoding: .utf8)
  print("Generated \(families.count) emoji search entries at \(outputURL.path)")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
