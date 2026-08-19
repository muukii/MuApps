#if TINYCURVE_PROFILE_IMAGE
  import CloudKit
  import Foundation
  import Observation

  /// App-lifetime state for the current Tinycurve user's optional public profile image.
  ///
  /// Profile identity is deliberately separate from `JournalVault`: a single image
  /// applies across every Vault and lives on the current user's public CloudKit
  /// `Users` record. `TinycurveApp` owns one instance and injects it into every scene.
  @MainActor
  @Observable
  final class JournalUserProfile {

    /// Result of the most recent profile load attempt.
    enum LoadState: Equatable {
      /// The profile has not contacted CloudKit yet.
      case idle

      /// The initial profile fetch is in progress.
      case loading

      /// CloudKit was reachable; `imageData` is either the saved JPEG or `nil`.
      case loaded

      /// The current device cannot use the app's iCloud container.
      case unavailable

      /// The initial fetch failed for a reason that can be retried.
      case failed
    }

    /// A network mutation currently owned by the profile screen.
    enum Mutation: Equatable {
      /// A new cropped JPEG is being uploaded.
      case saving

      /// The existing public profile image field is being cleared.
      case removing
    }

    /// Identifiable user-facing failure from the most recent operation.
    struct Failure: Identifiable, Equatable, Sendable {
      let id = UUID()
      let error: JournalUserProfileError

      /// Localized explanation suitable for a Settings alert.
      var message: String {
        error.localizedDescription
      }
    }

    /// Last successfully loaded or saved square JPEG.
    private(set) var imageData: Data?

    /// Current availability result for the public profile record.
    private(set) var loadState: LoadState = .idle

    /// Active save/remove mutation, if any.
    private(set) var mutation: Mutation?

    /// Most recent error awaiting user acknowledgement.
    private(set) var failure: Failure?

    /// Whether any load, save, or remove operation is currently in flight.
    var isBusy: Bool {
      loadState == .loading || isReloading || mutation != nil
    }

    /// Whether CloudKit is refreshing an already-resolved profile.
    private(set) var isReloading = false

    @ObservationIgnored private let client: JournalUserProfileClient

    init(client: JournalUserProfileClient) {
      self.client = client
    }

    /// Loads the profile once when Settings first needs it.
    func loadIfNeeded() async {
      guard loadState == .idle else { return }
      await reload()
    }

    /// Fetches the current `Users.profileImage` value without discarding a
    /// previously displayed image when a transient refresh fails.
    func reload() async {
      guard !isBusy else { return }

      let hadResolvedProfile = loadState == .loaded
      if hadResolvedProfile {
        isReloading = true
      } else {
        loadState = .loading
      }
      failure = nil

      defer { isReloading = false }

      do {
        imageData = try await client.fetch()
        loadState = .loaded
      } catch {
        let profileError = JournalUserProfileError.wrap(error)
        failure = Failure(error: profileError)
        if profileError.isICloudUnavailable {
          loadState = .unavailable
        } else if hadResolvedProfile {
          loadState = .loaded
        } else {
          loadState = .failed
        }
      }
    }

    /// Uploads a user-confirmed square JPEG to the public profile record.
    ///
    /// The model updates `imageData` only after CloudKit confirms the record-level
    /// save, so a failed upload never replaces the last known server value.
    @discardableResult
    func save(imageData: Data) async -> Bool {
      guard !isBusy else { return false }

      mutation = .saving
      failure = nil
      defer { mutation = nil }

      do {
        try await client.update(imageData)
        self.imageData = imageData
        loadState = .loaded
        return true
      } catch {
        handleMutationFailure(error)
        return false
      }
    }

    /// Clears only the optional public profile image field.
    ///
    /// The CloudKit system `Users` record itself must never be deleted.
    @discardableResult
    func removeImage() async -> Bool {
      guard !isBusy else { return false }

      mutation = .removing
      failure = nil
      defer { mutation = nil }

      do {
        try await client.update(nil)
        imageData = nil
        loadState = .loaded
        return true
      } catch {
        handleMutationFailure(error)
        return false
      }
    }

    /// Clears the current alert after SwiftUI dismisses it.
    func clearFailure() {
      failure = nil
    }

    private func handleMutationFailure(_ error: any Error) {
      let profileError = JournalUserProfileError.wrap(error)
      failure = Failure(error: profileError)
      if profileError.isICloudUnavailable {
        loadState = .unavailable
      }
    }
  }

  /// Sendable operations used by `JournalUserProfile`.
  ///
  /// A value of async closures keeps the UI model concrete while allowing tests
  /// to supply a network-free implementation. CloudKit transport remains hidden
  /// behind the live factory.
  nonisolated struct JournalUserProfileClient: Sendable {
    let fetch: @Sendable () async throws -> Data?
    let update: @Sendable (Data?) async throws -> Void

    /// Creates the production client for Tinycurve's configured CloudKit container.
    static func live(containerIdentifier: String) -> Self {
      let store = LiveJournalUserProfileCloudStore(containerIdentifier: containerIdentifier)
      return Self(
        fetch: { try await store.fetchImageData() },
        update: { try await store.updateImageData($0) }
      )
    }

    #if DEBUG
      /// Creates a network-free client for SwiftUI previews.
      static func preview(imageData: Data? = nil) -> Self {
        Self(
          fetch: { imageData },
          update: { _ in }
        )
      }
    #endif
  }

  /// Errors that map CloudKit account and record failures into profile UI states.
  nonisolated enum JournalUserProfileError: Error, Equatable, LocalizedError, Sendable {
    /// No iCloud account is available to this app.
    case iCloudAccountUnavailable

    /// The account is present but restricted from using iCloud.
    case iCloudAccountRestricted

    /// CloudKit could not determine the account state.
    case couldNotDetermineICloudStatus

    /// CloudKit reported a temporary account outage.
    case iCloudTemporarilyUnavailable

    /// A profile CKAsset did not contain a readable staging file.
    case profileImageUnavailable

    /// CloudKit omitted the per-record result for a requested save.
    case missingSaveResult

    /// Another file or CloudKit operation failed.
    case operationFailed(String)

    var errorDescription: String? {
      switch self {
      case .iCloudAccountUnavailable:
        String(localized: "Sign in to iCloud to use a Tinycurve profile image.")
      case .iCloudAccountRestricted:
        String(localized: "This iCloud account cannot use Tinycurve profile images.")
      case .couldNotDetermineICloudStatus:
        String(localized: "Tinycurve could not determine the current iCloud status. Try again.")
      case .iCloudTemporarilyUnavailable:
        String(localized: "iCloud is temporarily unavailable. Try again later.")
      case .profileImageUnavailable:
        String(localized: "The saved profile image could not be downloaded.")
      case .missingSaveResult:
        String(localized: "CloudKit did not confirm the profile image update.")
      case .operationFailed(let message):
        message
      }
    }

    /// Whether Settings should present a persistent iCloud-unavailable state.
    var isICloudUnavailable: Bool {
      switch self {
      case .iCloudAccountUnavailable, .iCloudAccountRestricted,
        .couldNotDetermineICloudStatus, .iCloudTemporarilyUnavailable:
        true
      case .profileImageUnavailable, .missingSaveResult, .operationFailed:
        false
      }
    }

    /// Preserves a domain error or wraps an unexpected underlying error.
    static func wrap(_ error: any Error) -> Self {
      if let profileError = error as? Self {
        return profileError
      }

      if let cloudKitError = error as? CKError {
        switch cloudKitError.code {
        case .notAuthenticated:
          return .iCloudAccountUnavailable
        case .accountTemporarilyUnavailable, .serviceUnavailable, .networkFailure,
          .networkUnavailable, .requestRateLimited, .zoneBusy:
          return .iCloudTemporarilyUnavailable
        default:
          break
        }
      }

      return .operationFailed(error.localizedDescription)
    }
  }

  /// Serialized CloudKit transport for the current user's public `Users` record.
  ///
  /// Mutable `CKRecord` values and CKAsset staging files stay actor-local so the
  /// observable app state never exposes CloudKit transport objects.
  private actor LiveJournalUserProfileCloudStore {

    /// Custom field deployed on CloudKit's public system `Users` record.
    ///
    /// Public database records can be read by other Tinycurve users when they
    /// already know this user's record ID; this field must not contain journal data.
    private static let profileImageField = "profileImage"

    private let container: CKContainer

    init(containerIdentifier: String) {
      container = CKContainer(identifier: containerIdentifier)
    }

    /// Reads CKAsset bytes immediately while CloudKit's staging URL is valid.
    func fetchImageData() async throws -> Data? {
      do {
        try await requireAvailableAccount()
        let userRecordID = try await container.userRecordID()
        let record = try await container.publicCloudDatabase.record(for: userRecordID)

        guard let asset = record[Self.profileImageField] as? CKAsset else {
          return nil
        }
        guard let fileURL = asset.fileURL else {
          throw JournalUserProfileError.profileImageUnavailable
        }

        return try Data(contentsOf: fileURL)
      } catch {
        throw JournalUserProfileError.wrap(error)
      }
    }

    /// Replaces or removes only `Users.profileImage` with changed-keys semantics.
    func updateImageData(_ imageData: Data?) async throws {
      do {
        try await requireAvailableAccount()
        let userRecordID = try await container.userRecordID()
        let record = try await container.publicCloudDatabase.record(for: userRecordID)

        if let imageData {
          let temporaryFileURL = try makeUploadFile(containing: imageData)
          defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

          // CKAsset reads this file during the asynchronous modify operation, so
          // its lifetime must extend until the awaited record result completes.
          record[Self.profileImageField] = CKAsset(fileURL: temporaryFileURL)
          try await saveChangedProfileField(record)
        } else {
          record[Self.profileImageField] = nil
          try await saveChangedProfileField(record)
        }
      } catch {
        throw JournalUserProfileError.wrap(error)
      }
    }

    private func requireAvailableAccount() async throws {
      switch try await container.accountStatus() {
      case .available:
        return
      case .noAccount:
        throw JournalUserProfileError.iCloudAccountUnavailable
      case .restricted:
        throw JournalUserProfileError.iCloudAccountRestricted
      case .couldNotDetermine:
        throw JournalUserProfileError.couldNotDetermineICloudStatus
      case .temporarilyUnavailable:
        throw JournalUserProfileError.iCloudTemporarilyUnavailable
      @unknown default:
        throw JournalUserProfileError.couldNotDetermineICloudStatus
      }
    }

    private func saveChangedProfileField(_ record: CKRecord) async throws {
      let result = try await container.publicCloudDatabase.modifyRecords(
        saving: [record],
        deleting: [],
        savePolicy: .changedKeys,
        atomically: false
      )

      guard let saveResult = result.saveResults[record.recordID] else {
        throw JournalUserProfileError.missingSaveResult
      }
      _ = try saveResult.get()
    }

    private func makeUploadFile(containing imageData: Data) throws -> URL {
      let directoryURL = FileManager.default.temporaryDirectory.appending(
        path: "TinycurveProfileImageUploads",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )

      let fileURL = directoryURL.appending(
        path: "\(UUID().uuidString).jpg",
        directoryHint: .notDirectory
      )
      try imageData.write(to: fileURL, options: .atomic)
      return fileURL
    }
  }
#endif
