import Testing

@testable import Tinycurve

@Suite("Journal feature flags")
@MainActor
struct JournalFeatureFlagsTests {

  @Test("Profile images follow the named compilation condition")
  func profileImageMatchesBuildConfiguration() {
    #if TINYCURVE_PROFILE_IMAGE
      #expect(JournalFeatureFlags.isProfileImageEnabled)
    #else
      #expect(!JournalFeatureFlags.isProfileImageEnabled)
    #endif
  }
}
