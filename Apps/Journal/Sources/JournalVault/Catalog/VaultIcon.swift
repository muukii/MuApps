import Foundation

/// User-facing mark assigned to a vault in catalog-level presentation surfaces.
///
/// The icon is metadata for selecting and recognizing a vault; card content and
/// sync state remain in the per-vault stores. `value` stores either an SF Symbol
/// name or an emoji string, depending on `kind`.
public struct VaultIcon: Codable, Hashable, Sendable {

  /// Rendering family for a vault icon.
  public enum Kind: String, Codable, Sendable {
    /// `value` is an SF Symbol name, for example `"shippingbox"`.
    case systemImage

    /// `value` is an emoji grapheme shown as text.
    case emoji
  }

  /// Default icon used for older catalog rows and newly materialized vaults.
  public static let `default` = VaultIcon(kind: .systemImage, value: "shippingbox")

  /// Rendering family for `value`.
  public let kind: Kind

  /// SF Symbol name or emoji string, depending on `kind`.
  public let value: String

  public init(kind: Kind, value: String) {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedValue.isEmpty {
      self.kind = Self.default.kind
      self.value = Self.default.value
    } else {
      self.kind = kind
      self.value = trimmedValue
    }
  }

  /// Creates an SF Symbol vault icon.
  public static func systemImage(_ name: String) -> VaultIcon {
    VaultIcon(kind: .systemImage, value: name)
  }

  /// Creates an emoji vault icon.
  public static func emoji(_ value: String) -> VaultIcon {
    VaultIcon(kind: .emoji, value: value)
  }
}
