import Foundation
import JournalVault
import Testing
import UserNotifications

@testable import Tinycurve

@Suite("System notification authorization")
@MainActor
struct SystemNotificationAuthorizationTests {

  @Test("Maps UserNotifications settings into the app-scoped status")
  func mapsSystemSettings() {
    #expect(
      SystemNotificationAuthorization.Status(
        snapshot: .init(
          authorization: .notDetermined,
          alert: .disabled,
          sound: .disabled
        )
      ) == .notDetermined
    )
    #expect(
      SystemNotificationAuthorization.Status(
        snapshot: .init(
          authorization: .denied,
          alert: .disabled,
          sound: .disabled
        )
      ) == .denied
    )
    #expect(
      SystemNotificationAuthorization.Status(
        snapshot: .init(
          authorization: .authorized,
          alert: .enabled,
          sound: .disabled
        )
      ) == .enabled(.immediate(alert: true, sound: false))
    )
    #expect(
      SystemNotificationAuthorization.Status(
        snapshot: .init(
          authorization: .provisional,
          alert: .disabled,
          sound: .disabled
        )
      ) == .enabled(.quiet(alert: false, sound: false))
    )
  }

  @Test("Only actual collaboration is eligible for an automatic primer")
  func checksPrimerEligibility() {
    let ownerOnly = SystemNotificationPrimerEligibility(
      isParticipant: false,
      participantCount: 1
    )
    let collaborativeOwner = SystemNotificationPrimerEligibility(
      isParticipant: false,
      participantCount: 2
    )
    let participant = SystemNotificationPrimerEligibility(
      isParticipant: true,
      participantCount: 1
    )

    #expect(
      !SystemNotificationPrimerPolicy.shouldOfferPrimer(
        for: .notDetermined,
        trigger: .ownerShareSavedAndDismissed(ownerOnly),
        hasDeferredForInstall: false
      )
    )
    #expect(
      SystemNotificationPrimerPolicy.shouldOfferPrimer(
        for: .notDetermined,
        trigger: .ownerShareSavedAndDismissed(collaborativeOwner),
        hasDeferredForInstall: false
      )
    )
    #expect(
      SystemNotificationPrimerPolicy.shouldOfferPrimer(
        for: .notDetermined,
        trigger: .existingCollaborativeVaultOpened(participant),
        hasDeferredForInstall: false
      )
    )
    #expect(
      SystemNotificationPrimerPolicy.shouldEvaluateExistingVault(after: .refreshed)
    )
    #expect(
      !SystemNotificationPrimerPolicy.shouldEvaluateExistingVault(after: .failed)
    )
  }

  @Test("Only one active scene can claim a contextual primer")
  func claimsPrimerForASingleActiveScene() {
    var presentation = SystemNotificationPrimerPresentation()
    let firstSceneID = UUID()
    let secondSceneID = UUID()

    let didEnqueue = presentation.enqueue()
    let didRejectInactiveScene = presentation.claim(for: firstSceneID, whenSceneIsActive: false)
    let didClaimFirstScene = presentation.claim(for: firstSceneID, whenSceneIsActive: true)
    let didRejectSecondScene = presentation.claim(for: secondSceneID, whenSceneIsActive: true)
    let didReleaseFirstScene = presentation.releaseClaim(for: firstSceneID)
    let didClaimSecondScene = presentation.claim(for: secondSceneID, whenSceneIsActive: true)
    let didResolveSecondScene = presentation.resolve(claimedBy: secondSceneID)

    #expect(didEnqueue)
    #expect(!didRejectInactiveScene)
    #expect(didClaimFirstScene)
    #expect(!didRejectSecondScene)
    #expect(didReleaseFirstScene)
    #expect(didClaimSecondScene)
    #expect(didResolveSecondScene)
    #expect(presentation.requestID == nil)
  }

  @Test("Not Now defers automatic primers for the current install")
  func recordsPrimerDeferral() throws {
    let suiteName = "SystemNotificationAuthorizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let authorization = SystemNotificationAuthorization(defaults: defaults)
    #expect(!authorization.hasDeferredPrimerForInstall)

    authorization.deferPrimer()

    #expect(authorization.hasDeferredPrimerForInstall)
    #expect(
      !SystemNotificationPrimerPolicy.shouldOfferPrimer(
        for: .notDetermined,
        trigger: .participantInitialImportCompleted,
        hasDeferredForInstall: authorization.hasDeferredPrimerForInstall
      )
    )
  }

  @Test("Denied alerts do not disable APNs registration")
  func registersForRemoteNotificationsWhenAlertsAreDenied() async {
    var registrations = 0
    let authorization = SystemNotificationAuthorization(
      notificationSettingsSnapshot: {
        .init(
          authorization: .denied,
          alert: .disabled,
          sound: .disabled
        )
      },
      remoteRegistration: {
        registrations += 1
      }
    )

    await authorization.refresh()

    #expect(authorization.status == .denied)
    #expect(registrations == 1)
  }

  @Test("Only visible Pulse subscriptions override foreground presentation")
  func filtersForegroundNotifications() {
    #expect(
      VaultNotificationPulseSubscription.titleLocalizationKey
        == "VAULT_ACTIVITY_NOTIFICATION_TITLE"
    )
    #expect(
      VaultNotificationPulseSubscription.bodyLocalizationKey
        == "VAULT_ACTIVITY_NOTIFICATION_BODY"
    )

    let pulseOptions = SystemNotificationForegroundPolicy.presentationOptions(
      for: .init(
        subscriptionID: VaultNotificationPulseSubscription.privateDatabaseIdentifier
      )
    )
    #expect(pulseOptions == [.banner, .list, .sound])

    let sharedPulseOptions = SystemNotificationForegroundPolicy.presentationOptions(
      for: .init(
        subscriptionID: VaultNotificationPulseSubscription.sharedDatabaseIdentifier
      )
    )
    #expect(sharedPulseOptions == [.banner, .list, .sound])

    let nonPulseOptions = SystemNotificationForegroundPolicy.presentationOptions(
      for: .init(
        subscriptionID: "tinycurve.vault-sync.private.v1"
      )
    )
    #expect(nonPulseOptions.isEmpty)

    let unknownOptions = SystemNotificationForegroundPolicy.presentationOptions(
      for: .init(
        subscriptionID: nil
      )
    )
    #expect(unknownOptions.isEmpty)
  }

  @Test("Test-host launch never selects the CloudKit runtime")
  func selectsLoggingRuntimeForHostedTests() {
    #expect(
      TinycurveRuntimeLaunchPolicy.runtimeMode(
        environment: ["XCTestConfigurationFilePath": "/tmp/Tinycurve.xctestconfiguration"]
      ) == .logging
    )
    #expect(
      TinycurveRuntimeLaunchPolicy.runtimeMode(
        environment: ["XCTestBundlePath": "/tmp/TinycurveTests.xctest"]
      ) == .logging
    )
    #expect(
      TinycurveRuntimeLaunchPolicy.runtimeMode(environment: ["PATH": "/usr/bin"]) == .cloudKit
    )
  }

  @Test("Visible Pulse localization resources remain in the app bundle")
  func retainsVisiblePulseLocalizationResources() throws {
    let appBundle = Bundle(for: TinycurveAppDelegate.self)
    let expectedValues = [
      (
        locale: "en",
        title: "Tinycurve",
        body: "There's an update in a shared Vault."
      ),
      (
        locale: "ja",
        title: "Tinycurve",
        body: "共有Vaultに更新があります。"
      ),
    ]

    for expected in expectedValues {
      let localizationURL = try #require(
        appBundle.url(forResource: expected.locale, withExtension: "lproj")
      )
      let localizationBundle = try #require(Bundle(url: localizationURL))
      #expect(
        localizationBundle.localizedString(
          forKey: VaultNotificationPulseSubscription.titleLocalizationKey,
          value: nil,
          table: "Localizable"
        ) == expected.title
      )
      #expect(
        localizationBundle.localizedString(
          forKey: VaultNotificationPulseSubscription.bodyLocalizationKey,
          value: nil,
          table: "Localizable"
        ) == expected.body
      )
    }
  }
}
