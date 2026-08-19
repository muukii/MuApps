#if TINYCURVE_PROFILE_IMAGE
  import Foundation
  import Testing

  @testable import Tinycurve

  @Suite("Current user profile state")
  @MainActor
  struct JournalUserProfileTests {

    @Test("The first load keeps its server image and does not refetch automatically")
    func loadIfNeededRunsOnce() async {
      let serverImage = Data([1, 2, 3])
      let backend = UserProfileTestBackend(imageData: serverImage)
      let profile = JournalUserProfile(client: backend.client)

      await profile.loadIfNeeded()
      await profile.loadIfNeeded()

      #expect(profile.loadState == .loaded)
      #expect(profile.imageData == serverImage)
      #expect(await backend.fetchCount == 1)
    }

    @Test("A confirmed save and remove update state only after the client succeeds")
    func saveAndRemove() async {
      let backend = UserProfileTestBackend(imageData: nil)
      let profile = JournalUserProfile(client: backend.client)
      await profile.loadIfNeeded()

      let croppedImage = Data([4, 5, 6])
      #expect(await profile.save(imageData: croppedImage))
      #expect(profile.imageData == croppedImage)
      #expect(await backend.imageData == croppedImage)

      #expect(await profile.removeImage())
      #expect(profile.imageData == nil)
      #expect(await backend.imageData == nil)
    }

    @Test("A failed save preserves the last server image")
    func failedSavePreservesImage() async {
      let serverImage = Data([7, 8, 9])
      let backend = UserProfileTestBackend(imageData: serverImage)
      let profile = JournalUserProfile(client: backend.client)
      await profile.loadIfNeeded()
      await backend.failNextUpdate(with: .operationFailed("Upload failed"))

      #expect(await profile.save(imageData: Data([10])) == false)
      #expect(profile.imageData == serverImage)
      #expect(profile.loadState == .loaded)
      #expect(profile.failure?.error == .operationFailed("Upload failed"))
    }

    @Test("A transient reload failure preserves an already displayed image")
    func failedReloadPreservesImage() async {
      let serverImage = Data([11, 12])
      let backend = UserProfileTestBackend(imageData: serverImage)
      let profile = JournalUserProfile(client: backend.client)
      await profile.loadIfNeeded()
      await backend.failNextFetch(with: .operationFailed("Refresh failed"))

      await profile.reload()

      #expect(profile.imageData == serverImage)
      #expect(profile.loadState == .loaded)
      #expect(profile.failure?.error == .operationFailed("Refresh failed"))
    }

    @Test("An unavailable iCloud account becomes a persistent availability state")
    func unavailableICloudAccount() async {
      let backend = UserProfileTestBackend(imageData: nil)
      await backend.failNextFetch(with: .iCloudAccountUnavailable)
      let profile = JournalUserProfile(client: backend.client)

      await profile.loadIfNeeded()

      #expect(profile.loadState == .unavailable)
      #expect(profile.imageData == nil)
      #expect(profile.failure?.error == .iCloudAccountUnavailable)
    }
  }

  /// Actor-backed CloudKit substitute used by profile state tests.
  private actor UserProfileTestBackend {

    private(set) var imageData: Data?
    private(set) var fetchCount = 0
    private var nextFetchError: JournalUserProfileError?
    private var nextUpdateError: JournalUserProfileError?

    init(imageData: Data?) {
      self.imageData = imageData
    }

    nonisolated var client: JournalUserProfileClient {
      JournalUserProfileClient(
        fetch: { try await self.fetch() },
        update: { try await self.update($0) }
      )
    }

    func failNextFetch(with error: JournalUserProfileError) {
      nextFetchError = error
    }

    func failNextUpdate(with error: JournalUserProfileError) {
      nextUpdateError = error
    }

    private func fetch() throws -> Data? {
      fetchCount += 1
      if let nextFetchError {
        self.nextFetchError = nil
        throw nextFetchError
      }
      return imageData
    }

    private func update(_ imageData: Data?) throws {
      if let nextUpdateError {
        self.nextUpdateError = nil
        throw nextUpdateError
      }
      self.imageData = imageData
    }
  }
#endif
