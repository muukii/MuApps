import Foundation
import Testing

@testable import JournalIntents
import JournalVault

struct JournalQuickCapturePreferencesTests {
  @Test
  func shareDestination_isEnvironmentScopedAndResolvesWritableDescriptor() throws {
    let suiteName = "JournalQuickCapturePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = JournalQuickCapturePreferences(suiteName: suiteName)
    let developmentVault = JournalWritableVault(id: VaultID(), title: "Development")
    let productionVault = JournalWritableVault(id: VaultID(), title: "Production")

    try preferences.setSelectedVault(developmentVault, environment: .development)
    try preferences.setSelectedVault(productionVault, environment: .production)

    #expect(try preferences.selectedVaultID(environment: .development) == developmentVault.id)
    #expect(try preferences.selectedVaultID(environment: .production) == productionVault.id)
    #expect(
      try preferences.selectedVault(
        from: [developmentVault, productionVault],
        environment: .development
      ) == developmentVault
    )
  }

  @Test
  func shareDestination_doesNotFallbackWhenStoredVaultIsNoLongerWritable() throws {
    let suiteName = "JournalQuickCapturePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = JournalQuickCapturePreferences(suiteName: suiteName)
    let removedVault = JournalWritableVault(id: VaultID(), title: "Removed")
    let otherVault = JournalWritableVault(id: VaultID(), title: "Other")
    try preferences.setSelectedVault(removedVault, environment: .development)

    let resolved = try preferences.selectedVault(
      from: [otherVault],
      environment: .development
    )

    #expect(resolved == nil)
  }
}
