import Foundation
import Testing

@testable import JournalVault

struct VaultSyncEngineStateEnvelopeTests {

  @Test
  func matchingEnvelope_restoresStateAndUsesSortedRecordTypes() throws {
    let expected = TestState(token: "current")
    let data = try VaultSyncEngineStateEnvelope.current(serialization: expected).encoded()

    switch VaultSyncEngineStateEnvelope.restore(from: data, as: TestState.self) {
    case .restored(let restored):
      #expect(restored == expected)
    case .requiresFullRefetch:
      #expect(Bool(false))
    }

    #expect(
      VaultSyncEngineStateEnvelope.currentKnownRecordTypes
        == VaultSyncEngineStateEnvelope.currentKnownRecordTypes.sorted()
    )
    #expect(
      VaultSyncEngineStateEnvelope.currentKnownRecordTypes
        == VaultRecordType.allCases.map(\.rawValue).sorted()
    )
  }

  @Test
  func legacyRawSerialization_requiresFullRefetch() throws {
    let legacyRawState = try JSONEncoder().encode(TestState(token: "legacy"))

    #expect(requiresFullRefetch(legacyRawState))
  }

  @Test
  func addedRecordType_requiresFullRefetch() throws {
    let envelope = try makeEnvelope(
      knownRecordTypes: VaultSyncEngineStateEnvelope.currentKnownRecordTypes + ["FutureVaultRecord"]
    )

    #expect(requiresFullRefetch(try envelope.encoded()))
  }

  @Test
  func removedRecordType_requiresFullRefetch() throws {
    let knownTypes = VaultSyncEngineStateEnvelope.currentKnownRecordTypes
    let envelope = try makeEnvelope(knownRecordTypes: Array(knownTypes.dropFirst()))

    #expect(requiresFullRefetch(try envelope.encoded()))
  }

  @Test
  func decoderCompatibilityGenerationBump_requiresFullRefetch() throws {
    let envelope = try makeEnvelope(
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration - 1
    )

    #expect(requiresFullRefetch(try envelope.encoded()))
  }

  @Test
  func envelopeFormatVersionBump_requiresFullRefetch() throws {
    let envelope = VaultSyncEngineStateEnvelope(
      formatVersion: VaultSyncEngineStateEnvelope.formatVersion + 1,
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration,
      knownRecordTypes: VaultSyncEngineStateEnvelope.currentKnownRecordTypes,
      serialization: try JSONEncoder().encode(TestState(token: "state"))
    )

    #expect(requiresFullRefetch(try envelope.encoded()))
  }

  @Test
  func malformedNestedSerialization_requiresFullRefetch() throws {
    let envelope = VaultSyncEngineStateEnvelope(
      formatVersion: VaultSyncEngineStateEnvelope.formatVersion,
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration,
      knownRecordTypes: VaultSyncEngineStateEnvelope.currentKnownRecordTypes,
      serialization: Data("not a JSON serialization".utf8)
    )

    #expect(requiresFullRefetch(try envelope.encoded()))
  }

  @Test
  func incompatibleEnvelope_becomesCurrentEmptyMarkerAfterOneInvalidation() throws {
    let incompatible = try makeEnvelope(
      schemaCompatibilityGeneration: VaultCloudKitSchema.syncStateCompatibilityGeneration - 1
    )
    #expect(requiresFullRefetch(try incompatible.encoded()))

    let currentEmptyData = try VaultSyncEngineStateEnvelope.emptyCurrent.encoded()
    switch VaultSyncEngineStateEnvelope.restore(from: currentEmptyData, as: TestState.self) {
    case .restored(let restored):
      #expect(restored == nil)
    case .requiresFullRefetch:
      #expect(Bool(false))
    }
  }

  @Test
  func currentEngineIdentity_rejectsLateStateUpdatesFromReplacedEngine() {
    let current = NSObject()
    let replaced = NSObject()

    #expect(CloudKitVaultSyncEngine.isCurrentEngine(current, currentEngine: current))
    #expect(CloudKitVaultSyncEngine.isCurrentEngine(replaced, currentEngine: current) == false)
    #expect(CloudKitVaultSyncEngine.isCurrentEngine(current, currentEngine: nil) == false)
  }

  private func makeEnvelope(
    schemaCompatibilityGeneration: Int = VaultCloudKitSchema.syncStateCompatibilityGeneration,
    knownRecordTypes: [String] = VaultSyncEngineStateEnvelope.currentKnownRecordTypes
  ) throws -> VaultSyncEngineStateEnvelope {
    VaultSyncEngineStateEnvelope(
      formatVersion: VaultSyncEngineStateEnvelope.formatVersion,
      schemaCompatibilityGeneration: schemaCompatibilityGeneration,
      knownRecordTypes: knownRecordTypes,
      serialization: try JSONEncoder().encode(TestState(token: "state"))
    )
  }

  private func requiresFullRefetch(_ data: Data) -> Bool {
    if case .requiresFullRefetch = VaultSyncEngineStateEnvelope.restore(
      from: data,
      as: TestState.self
    ) {
      return true
    }
    return false
  }
}

private struct TestState: Codable, Equatable, Sendable {
  let token: String
}
