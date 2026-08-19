import Foundation

/// Versioned local wrapper for a `CKSyncEngine` state serialization.
///
/// A `CKSyncEngine` token says which remote changes this build has consumed,
/// but it cannot say whether this build could *understand* every consumed
/// record. The wrapper persists the record-type manifest and an explicit
/// decoder-compatibility generation beside the token. A later build with a
/// different compatibility contract starts from empty state once, so CloudKit
/// replays records an older build intentionally left unmaterialized.
///
/// The nested serialization is encoded bytes rather than a direct
/// `CKSyncEngine.State.Serialization` property. This keeps envelope
/// compatibility testable without constructing CloudKit runtime state and
/// makes malformed inner data fail closed independently from the envelope
/// header.
struct VaultSyncEngineStateEnvelope: Codable, Sendable {

  /// Bump only when this envelope's own Codable layout changes incompatibly.
  static let formatVersion = 1

  /// Canonical, stable record-type manifest written with every state update.
  static let currentKnownRecordTypes = VaultRecordType.allCases.map(\.rawValue).sorted()

  /// Version of this envelope's Codable layout.
  let formatVersion: Int

  /// Version of the remote record materialization contract.
  let schemaCompatibilityGeneration: Int

  /// Sorted CloudKit record types the writing build recognized.
  let knownRecordTypes: [String]

  /// JSON bytes for `CKSyncEngine.State.Serialization`; `nil` records that an
  /// incompatible legacy state was intentionally invalidated and must refetch.
  let serialization: Data?

  init(
    formatVersion: Int,
    schemaCompatibilityGeneration: Int,
    knownRecordTypes: [String],
    serialization: Data?
  ) {
    self.formatVersion = formatVersion
    self.schemaCompatibilityGeneration = schemaCompatibilityGeneration
    self.knownRecordTypes = knownRecordTypes.sorted()
    self.serialization = serialization
  }

  /// Wraps a current CloudKit state update for durable persistence.
  static func current<Serialization: Encodable>(serialization: Serialization) throws -> Self {
    try Self(
      formatVersion: formatVersion,
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration,
      knownRecordTypes: currentKnownRecordTypes,
      serialization: JSONEncoder().encode(serialization)
    )
  }

  /// Current compatibility metadata with no resumable CloudKit token.
  ///
  /// This marker turns a legacy/mismatched token invalidation into a one-shot
  /// operation even if the app terminates before `CKSyncEngine` emits its next
  /// state update.
  static var emptyCurrent: Self {
    Self(
      formatVersion: formatVersion,
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration,
      knownRecordTypes: currentKnownRecordTypes,
      serialization: nil
    )
  }

  /// Whether this envelope can safely resume the current build's token.
  var isCurrentCompatible: Bool {
    formatVersion == Self.formatVersion
      && schemaCompatibilityGeneration == VaultCloudKitSchema.syncStateCompatibilityGeneration
      && knownRecordTypes == Self.currentKnownRecordTypes
  }

  /// Result of restoring an envelope for one concrete serialization type.
  enum Restoration<Serialization: Sendable>: Sendable {
    /// A compatible envelope; `nil` means this build must perform its initial
    /// full fetch because a prior launch intentionally invalidated the token.
    case restored(Serialization?)

    /// Legacy, mismatched, or malformed state. The caller must replace it with
    /// `emptyCurrent` and construct `CKSyncEngine` without a token.
    case requiresFullRefetch
  }

  /// Decodes a persisted envelope and validates its compatibility contract.
  static func restore<Serialization: Decodable & Sendable>(
    from data: Data,
    as serializationType: Serialization.Type
  ) -> Restoration<Serialization> {
    guard
      let envelope = try? JSONDecoder().decode(Self.self, from: data),
      envelope.isCurrentCompatible
    else {
      return .requiresFullRefetch
    }

    guard let serializationData = envelope.serialization else {
      return .restored(nil)
    }
    guard let serialization = try? JSONDecoder().decode(serializationType, from: serializationData)
    else {
      return .requiresFullRefetch
    }
    return .restored(serialization)
  }

  /// Encodes this envelope atomically with its own header and payload.
  func encoded() throws -> Data {
    try JSONEncoder().encode(self)
  }
}
