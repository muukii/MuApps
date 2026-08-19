import JournalVault
import Testing

@testable import Tinycurve

@Suite("Vault system sharing coordinator")
@MainActor
struct VaultSystemSharingCoordinatorTests {

  @Test("A primer waits for all success facts in any callback order")
  func waitsForAllSuccessFacts() {
    var lifecycle = VaultOwnerSharePresentationLifecycle(vaultID: VaultID())

    lifecycle.recordPresentationDismissal()
    lifecycle.recordSystemShareSave()
    #expect(!lifecycle.isReadyForPrimer)

    lifecycle.recordActivityCompletion(true)
    #expect(lifecycle.isReadyForPrimer)
  }

  @Test("Cancellation is terminal despite late activity and observer callbacks")
  func ignoresLateCallbacksAfterCancellation() {
    var lifecycle = VaultOwnerSharePresentationLifecycle(vaultID: VaultID())

    lifecycle.recordActivityCompletion(false)
    lifecycle.recordPresentationDismissal()
    lifecycle.recordSystemShareSave()
    lifecycle.recordActivityCompletion(true)

    #expect(lifecycle.isTerminal)
    #expect(!lifecycle.isReadyForPrimer)
  }

  @Test("A failed observer save cannot be revived by a later save")
  func ignoresLateSaveAfterObserverFailure() {
    var lifecycle = VaultOwnerSharePresentationLifecycle(vaultID: VaultID())

    lifecycle.recordSystemShareFailure()
    lifecycle.recordSystemShareSave()
    lifecycle.recordPresentationDismissal()
    lifecycle.recordActivityCompletion(true)

    #expect(lifecycle.isTerminal)
    #expect(!lifecycle.isReadyForPrimer)
  }
}
