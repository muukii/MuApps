//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation
import Observation
import UniformTypeIdentifiers

/// A validated staged LUT whose heavyweight cube data has been released.
private struct PreparedLinkedLUT: Sendable {
  var change: LUTFolderSyncChange
  var lut: LUT
  var stagedURL: URL
}

/// The user's LUT collection: installs bundled starter content, imports `.cube`
/// / image LUTs from Files, persists a JSON index, synchronizes linked folders,
/// and materializes features.
@MainActor
@Observable
final class LUTLibrary {

  /// The app-owned LUT that establishes the initial library on a new install.
  ///
  /// The fixed identifier lets launch recover a removed Application Support
  /// copy without duplicating the LUT on every subsequent launch.
  private enum BundledStarterLUT {
    static let id = "farg.bundled.apple-log1-example"
    static let resourceName = "AppleLog1 Example"
    static let fileExtension = "cube"
  }

  enum LibraryError: LocalizedError {
    case unsupportedType(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedType(let ext):
        return "Unsupported LUT type: .\(ext). Import a .cube, .png, or .jpg file."
      }
    }
  }

  /// The private-library LUTs available to the editor.
  private(set) var luts: [LUT] = []

  /// Directories the user authorized as renewable LUT sources.
  private(set) var linkedFolders: [LUTFolderLink] = []

  /// LUTs imported independently or retained after unlinking their folder.
  private(set) var importedLUTs: [LUT] = []

  /// Linked LUTs grouped by their Files directory hierarchy.
  private(set) var linkedFolderCollections: [LUTFolderCollection] = []

  /// Access or automatic synchronization failures keyed by linked-folder id.
  private(set) var linkedFolderErrors: [String: String] = [:]

  /// Active synchronization progress keyed by linked-folder id.
  private(set) var linkedFolderSyncProgress:
    [String: LUTFolderSyncProgress] = [:]

  /// Whether a linked-folder refresh is currently reading File Providers.
  private(set) var isRefreshingLinkedFolders = false

  /// Advances when a sync changes LUT bytes without necessarily changing ids.
  private(set) var revision: UInt = 0

  /// Materialized features keyed by LUT id (cubeData is multi-MB, so cache it).
  private var featureCache: [String: ColorCubeFeature] = [:]

  private let fileManager = FileManager.default
  @ObservationIgnored private var isLinkedFolderObservationActive = false
  @ObservationIgnored private var folderPresenters: [String: LUTFolderPresenter] = [:]
  @ObservationIgnored private var presenterRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var needsLinkedFolderRefresh = false
  @ObservationIgnored private var linkedFolderRefreshWaiters:
    [CheckedContinuation<Void, Never>] = []

  init() {
    load()
    installBundledStarterLUTIfNeeded()
    migrateLinkedCubeDisplayNamesIfNeeded()
    rebuildOrganization()
  }

  // MARK: - Import

  /// Imports the bundled starter LUT only when its record or stored copy is
  /// absent, using the same validation and private storage boundary as Files.
  private func installBundledStarterLUTIfNeeded() {
    if let existingLUT = luts.first(where: { $0.id == BundledStarterLUT.id }),
      fileManager.fileExists(atPath: resolveURL(existingLUT).path)
    {
      return
    }

    guard
      let sourceURL = Bundle.main.url(
        forResource: BundledStarterLUT.resourceName,
        withExtension: BundledStarterLUT.fileExtension
      )
    else {
      assertionFailure("Missing bundled starter LUT resource.")
      return
    }

    let storedFileName = "\(UUID().uuidString).\(BundledStarterLUT.fileExtension)"
    let destinationURL = storageDirectory.appendingPathComponent(storedFileName)

    do {
      try createStorageDirectoryIfNeeded()
      try fileManager.copyItem(at: sourceURL, to: destinationURL)

      let feature = try Self.makeFeature(
        format: .cube,
        url: destinationURL,
        id: BundledStarterLUT.id,
        fallbackName: BundledStarterLUT.resourceName,
        amount: 1
      )
      let starterLUT = LUT(
        id: BundledStarterLUT.id,
        name: BundledStarterLUT.resourceName,
        format: .cube,
        dimension: feature.dimension,
        storedFileName: storedFileName
      )
      let updatedLUTs =
        [starterLUT]
        + luts.filter {
          $0.id != BundledStarterLUT.id
        }

      try persist(luts: updatedLUTs, linkedFolders: linkedFolders)
      luts = updatedLUTs
      featureCache[starterLUT.id] = feature
      revision &+= 1
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      assertionFailure("Failed to install bundled starter LUT: \(error)")
    }
  }

  /// The content types accepted by the Files importer.
  static var importableContentTypes: [UTType] {
    var types: [UTType] = [.png, .jpeg]
    if let cube = UTType(filenameExtension: "cube", conformingTo: .data) {
      types.insert(cube, at: 0)
    }
    return types
  }

  /// Imports a LUT from a (security-scoped) Files URL, copying it into storage.
  @discardableResult
  func importLUT(from pickedURL: URL) throws -> LUT {
    let didScope = pickedURL.startAccessingSecurityScopedResource()
    defer {
      if didScope { pickedURL.stopAccessingSecurityScopedResource() }
    }

    let ext = pickedURL.pathExtension.lowercased()
    guard let format = LUT.Format(fileExtension: ext) else {
      throw LibraryError.unsupportedType(ext)
    }

    try createStorageDirectoryIfNeeded()
    let storedName = "\(UUID().uuidString).\(ext)"
    let destination = storageDirectory.appendingPathComponent(storedName)
    try fileManager.copyItem(at: pickedURL, to: destination)

    do {
      let id = UUID().uuidString
      // Build once to validate the file and learn its real name / dimension.
      let feature = try Self.makeFeature(
        format: format,
        url: destination,
        id: id,
        fallbackName: pickedURL.deletingPathExtension().lastPathComponent,
        amount: 1
      )

      let lut = LUT(
        id: id,
        name: feature.name,
        format: format,
        dimension: feature.dimension,
        storedFileName: storedName
      )
      let updatedLUTs = [lut] + luts
      try persist(luts: updatedLUTs, linkedFolders: linkedFolders)
      luts = updatedLUTs
      rebuildOrganization()
      featureCache[id] = feature
      revision &+= 1
      return lut
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  // MARK: - Delete

  /// Deletes a manually imported LUT after its index update is durable.
  func delete(_ lut: LUT) throws {
    guard lut.canDeleteManually else { return }

    let updatedLUTs = luts.filter { $0.id != lut.id }
    try persist(luts: updatedLUTs, linkedFolders: linkedFolders)
    luts = updatedLUTs
    rebuildOrganization()
    featureCache[lut.id] = nil
    try? fileManager.removeItem(
      at: storageDirectory.appendingPathComponent(lut.storedFileName)
    )
    revision &+= 1
  }

  // MARK: - Linked folders

  /// Creates a persistent link and immediately discovers its initial changes.
  @discardableResult
  func linkFolder(from pickedURL: URL) async throws -> LUTFolderLink {
    let bookmarkData = try LUTFolderScanner.makeBookmark(for: pickedURL)
    let linkedFolder: LUTFolderLink
    if let existingIndex = linkedFolders.firstIndex(
      where: { $0.bookmarkData == bookmarkData }
    ) {
      var updatedFolders = linkedFolders
      updatedFolders[existingIndex].displayName = pickedURL.lastPathComponent
      try persist(luts: luts, linkedFolders: updatedFolders)
      linkedFolders = updatedFolders
      rebuildOrganization()
      linkedFolder = updatedFolders[existingIndex]
    } else {
      var updatedFolders = linkedFolders
      let newFolder = LUTFolderLink(
        id: UUID().uuidString,
        displayName: pickedURL.lastPathComponent,
        bookmarkData: bookmarkData,
        lastScannedAt: nil
      )
      updatedFolders.append(newFolder)
      try persist(luts: luts, linkedFolders: updatedFolders)
      linkedFolders = updatedFolders
      rebuildOrganization()
      linkedFolder = newFolder
    }

    await refreshLinkedFolders()
    return linkedFolder
  }

  /// Stops syncing a directory while preserving its current LUT copies.
  func unlinkFolder(_ folder: LUTFolderLink) throws {
    var updatedLUTs = luts
    for index in updatedLUTs.indices {
      guard updatedLUTs[index].linkedFolderOrigin?.folderID == folder.id else {
        continue
      }
      updatedLUTs[index].linkedFolderOrigin = nil
    }
    let updatedFolders = linkedFolders.filter { $0.id != folder.id }

    try persist(luts: updatedLUTs, linkedFolders: updatedFolders)
    luts = updatedLUTs
    linkedFolders = updatedFolders
    rebuildOrganization()
    linkedFolderErrors[folder.id] = nil
    removeFolderPresenter(folderID: folder.id)
    revision &+= 1
  }

  /// Scans every link away from the main actor and applies changes automatically.
  func refreshLinkedFolders() async {
    if isRefreshingLinkedFolders {
      needsLinkedFolderRefresh = true
      await withCheckedContinuation { continuation in
        linkedFolderRefreshWaiters.append(continuation)
      }
      return
    }

    // Previous processes may have terminated during a large first import.
    // The persisted library never points into staging, so these copies are
    // always safe to reclaim before the next serialized refresh begins.
    try? fileManager.removeItem(at: syncStagingDirectory)
    isRefreshingLinkedFolders = true
    repeat {
      needsLinkedFolderRefresh = false
      await performLinkedFolderRefresh()
    } while needsLinkedFolderRefresh
    isRefreshingLinkedFolders = false

    let waiters = linkedFolderRefreshWaiters
    linkedFolderRefreshWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func performLinkedFolderRefresh() async {
    let folders = linkedFolders
    var errors: [String: String] = [:]
    var resolvedDirectories: [String: URL] = [:]

    for scannedFolder in folders {
      linkedFolderSyncProgress[scannedFolder.id] = LUTFolderSyncProgress(
        phase: .scanning,
        completedCount: 0,
        totalCount: nil
      )
      do {
        defer {
          linkedFolderSyncProgress[scannedFolder.id] = nil
        }
        let result = try await Task.detached(priority: .utility) {
          try LUTFolderScanner.scan(scannedFolder)
        }.value
        guard let folder = linkedFolders.first(
          where: { $0.id == scannedFolder.id }
        ) else {
          continue
        }
        resolvedDirectories[folder.id] = result.resolvedDirectoryURL

        let plan = LUTFolderSyncPlan.make(
          folder: folder,
          scannedFiles: result.files,
          currentLUTs: luts
        )
        if plan.isEmpty {
          try updateLinkedFolderAfterScan(folder, result: result)
        } else {
          try await synchronizeFolder(
            plan: plan,
            folder: folder,
            scanResult: result
          )
        }
      } catch {
        errors[scannedFolder.id] = error.localizedDescription
        linkedFolderSyncProgress[scannedFolder.id] = nil
      }
    }

    linkedFolderErrors = errors
    if isLinkedFolderObservationActive {
      installFolderPresenters(resolvedDirectories: resolvedDirectories)
    }
  }

  /// Registers foreground-only file presenters and synchronizes current changes.
  func activateLinkedFolderObservation() async {
    isLinkedFolderObservationActive = true
    await refreshLinkedFolders()
  }

  /// Removes file presenters before iOS suspends the app.
  func deactivateLinkedFolderObservation() {
    isLinkedFolderObservationActive = false
    presenterRefreshTask?.cancel()
    presenterRefreshTask = nil
    removeAllFolderPresenters()
  }

  /// Applies one freshly scanned plan as a durable automatic synchronization.
  private func synchronizeFolder(
    plan: LUTFolderSyncPlan,
    folder: LUTFolderLink,
    scanResult: LUTFolderScanResult
  ) async throws {
    try createStorageDirectoryIfNeeded()
    // A terminated import can leave only app-owned temporary copies behind.
    // A new serialized refresh supersedes them, so reclaim them before retrying.
    try? fileManager.removeItem(at: syncStagingDirectory)
    let stagingDirectory = syncStagingDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )

    let copyProgress = AsyncStream.makeStream(
      of: LUTFolderSyncProgress.self
    )
    let copyTask = Task.detached(priority: .userInitiated) {
      defer { copyProgress.continuation.finish() }
      return try LUTFolderScanner.copyChangedFiles(
        in: plan,
        folder: folder,
        to: stagingDirectory,
        progress: { completed, total in
          copyProgress.continuation.yield(
            LUTFolderSyncProgress(
              phase: .copying,
              completedCount: completed,
              totalCount: total
            )
          )
        }
      )
    }
    for await progress in copyProgress.stream {
      guard linkedFolders.contains(where: { $0.id == folder.id }) else {
        continue
      }
      linkedFolderSyncProgress[folder.id] = progress
    }
    let stagedFiles = try await copyTask.value

    guard linkedFolders.contains(where: { $0.id == folder.id }) else {
      try? fileManager.removeItem(at: stagingDirectory)
      return
    }

    let validationProgress = AsyncStream.makeStream(
      of: LUTFolderSyncProgress.self
    )
    let validationTask = Task.detached(priority: .userInitiated) {
      defer { validationProgress.continuation.finish() }
      let changes = plan.changes.filter {
        switch $0.kind {
        case .added, .updated:
          return true
        case .removed:
          return false
        }
      }
      validationProgress.continuation.yield(
        LUTFolderSyncProgress(
          phase: .validating,
          completedCount: 0,
          totalCount: changes.count
        )
      )

      var prepared: [PreparedLinkedLUT] = []
      prepared.reserveCapacity(changes.count)

      for (index, change) in changes.enumerated() {
        guard let stagedURL = stagedFiles[change.relativePath],
              let fingerprint = change.fingerprint,
              let format = LUT.Format(fileExtension: stagedURL.pathExtension)
        else {
          throw LUTFolderScanner.ScannerError.missingSourceFile(
            change.relativePath
          )
        }

        let id = change.existingLUTID ?? UUID().uuidString
        let fallbackName = URL(filePath: change.relativePath)
          .deletingPathExtension()
          .lastPathComponent

        // The feature's cube data can be several megabytes. Validate one file
        // at a time and retain only metadata so a large folder stays bounded.
        let metadata = try autoreleasepool {
          let feature = try Self.makeFeature(
            format: format,
            url: stagedURL,
            id: id,
            fallbackName: fallbackName,
            amount: 1
          )
          return (name: feature.name, dimension: feature.dimension)
        }

        prepared.append(
          PreparedLinkedLUT(
            change: change,
            lut: LUT(
              id: id,
              name: metadata.name,
              format: format,
              dimension: metadata.dimension,
              storedFileName: stagedURL.lastPathComponent,
              linkedFolderOrigin: LUT.LinkedFolderOrigin(
                folderID: folder.id,
                relativePath: change.relativePath,
                fingerprint: fingerprint
              )
            ),
            stagedURL: stagedURL
          )
        )
        validationProgress.continuation.yield(
          LUTFolderSyncProgress(
            phase: .validating,
            completedCount: index + 1,
            totalCount: changes.count
          )
        )
      }
      return prepared
    }

    for await progress in validationProgress.stream {
      guard linkedFolders.contains(where: { $0.id == folder.id }) else {
        continue
      }
      linkedFolderSyncProgress[folder.id] = progress
    }

    let prepared: [PreparedLinkedLUT]
    do {
      prepared = try await validationTask.value
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }

    guard linkedFolders.contains(where: { $0.id == folder.id }) else {
      try? fileManager.removeItem(at: stagingDirectory)
      return
    }

    linkedFolderSyncProgress[folder.id] = LUTFolderSyncProgress(
      phase: .installing,
      completedCount: 0,
      totalCount: prepared.count
    )
    await Task.yield()

    var installedURLs: [URL] = []
    do {
      for (index, item) in prepared.enumerated() {
        guard linkedFolders.contains(where: { $0.id == folder.id }) else {
          throw CancellationError()
        }
        let destinationURL = storageDirectory.appending(
          path: item.stagedURL.lastPathComponent,
          directoryHint: .notDirectory
        )
        try fileManager.moveItem(at: item.stagedURL, to: destinationURL)
        installedURLs.append(destinationURL)
        linkedFolderSyncProgress[folder.id] = LUTFolderSyncProgress(
          phase: .installing,
          completedCount: index + 1,
          totalCount: prepared.count
        )
        if index.isMultiple(of: 16) {
          await Task.yield()
        }
      }
    } catch {
      for url in installedURLs {
        try? fileManager.removeItem(at: url)
      }
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }

    let existingByID = Dictionary(uniqueKeysWithValues: luts.map { ($0.id, $0) })
    var updatedLUTs = luts
    var obsoleteFileNames: [String] = []

    for change in plan.changes {
      switch change.kind {
      case .added:
        guard let item = prepared.first(
          where: { $0.change.relativePath == change.relativePath }
        ) else {
          continue
        }
        updatedLUTs.insert(item.lut, at: 0)
      case .updated:
        guard let id = change.existingLUTID,
              let index = updatedLUTs.firstIndex(where: { $0.id == id }),
              let item = prepared.first(where: { $0.lut.id == id })
        else {
          continue
        }
        obsoleteFileNames.append(updatedLUTs[index].storedFileName)
        updatedLUTs[index] = item.lut
      case .removed:
        guard let id = change.existingLUTID else { continue }
        if let old = existingByID[id] {
          obsoleteFileNames.append(old.storedFileName)
        }
        updatedLUTs.removeAll { $0.id == id }
      }
    }

    var updatedFolders = linkedFolders
    if let index = updatedFolders.firstIndex(where: { $0.id == folder.id }) {
      updatedFolders[index].lastScannedAt = Date()
      if let renewedBookmarkData = scanResult.renewedBookmarkData {
        updatedFolders[index].bookmarkData = renewedBookmarkData
      }
    }

    do {
      try persist(luts: updatedLUTs, linkedFolders: updatedFolders)
    } catch {
      for url in installedURLs {
        try? fileManager.removeItem(at: url)
      }
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }

    luts = updatedLUTs
    linkedFolders = updatedFolders
    rebuildOrganization()
    for change in plan.changes {
      if let id = change.existingLUTID {
        featureCache[id] = nil
      }
    }
    for fileName in obsoleteFileNames {
      try? fileManager.removeItem(
        at: storageDirectory.appending(
          path: fileName,
          directoryHint: .notDirectory
        )
      )
    }
    try? fileManager.removeItem(at: stagingDirectory)
    revision &+= 1
  }

  /// Persists scan metadata when no LUT bytes need to change.
  private func updateLinkedFolderAfterScan(
    _ folder: LUTFolderLink,
    result: LUTFolderScanResult
  ) throws {
    guard let index = linkedFolders.firstIndex(
      where: { $0.id == folder.id }
    ) else {
      return
    }
    var updatedFolders = linkedFolders
    updatedFolders[index].lastScannedAt = Date()
    if let renewedBookmarkData = result.renewedBookmarkData {
      updatedFolders[index].bookmarkData = renewedBookmarkData
    }
    try persist(luts: luts, linkedFolders: updatedFolders)
    linkedFolders = updatedFolders
    rebuildOrganization()
  }

  func lut(id: String) -> LUT? {
    luts.first { $0.id == id }
  }

  /// Resolves only the file metadata needed by the thumbnail renderer.
  ///
  /// Unlike `feature(for:)`, this path does not retain every decoded cube in the
  /// live editing cache. The preview renderer owns a separate cost-limited cache.
  func previewRecipe(for lut: LUT) throws -> LUTPreviewRecipe {
    LUTPreviewRecipe(
      lutID: lut.id,
      name: lut.name,
      format: lut.format,
      fileURL: resolveURL(lut)
    )
  }

  // MARK: - Feature materialization

  /// Resolves a LUT into a `ColorCubeFeature`, applying `amount` and a stable
  /// `FeatureID` so equal selections compare equal and the CI filter caches.
  func feature(for lut: LUT, amount: Double = 1) throws -> ColorCubeFeature {
    let base: ColorCubeFeature
    if let cached = featureCache[lut.id] {
      base = cached
    } else {
      base = try Self.makeFeature(
        format: lut.format,
        url: resolveURL(lut),
        id: lut.id,
        fallbackName: lut.name,
        amount: 1
      )
      featureCache[lut.id] = base
    }

    return ColorCubeFeature(
      id: FeatureID(rawValue: lut.id),
      name: base.name,
      identifier: lut.id,
      amount: amount,
      dimension: base.dimension,
      cubeData: base.cubeData
    )
  }

  private nonisolated static func makeFeature(
    format: LUT.Format,
    url: URL,
    id: String,
    fallbackName: String,
    amount: Double
  ) throws -> ColorCubeFeature {
    switch format {
    case .cube:
      return try ColorCubeFeature(
        contentsOfCubeFile: url,
        id: FeatureID(rawValue: id),
        name: fallbackName,
        amount: amount
      )
    case .image:
      return try ColorCubeFeature(
        cubeImageAt: url,
        id: FeatureID(rawValue: id),
        name: fallbackName,
        amount: amount
      )
    }
  }

  private func resolveURL(_ lut: LUT) -> URL {
    storageDirectory.appendingPathComponent(lut.storedFileName)
  }

  /// Replaces embedded `.cube` titles with their linked source file names.
  ///
  /// Resolve commonly writes the same generic `TITLE` into many LUTs. Linked
  /// origins retain the original relative path, so existing libraries can
  /// migrate without reopening or parsing their external files.
  private func migrateLinkedCubeDisplayNamesIfNeeded() {
    var updatedLUTs = luts
    var didChange = false

    for index in updatedLUTs.indices {
      guard
        updatedLUTs[index].format == .cube,
        let origin = updatedLUTs[index].linkedFolderOrigin
      else {
        continue
      }
      let fileName = URL(filePath: origin.relativePath)
        .deletingPathExtension()
        .lastPathComponent
      guard
        fileName.isEmpty == false,
        updatedLUTs[index].name != fileName
      else {
        continue
      }
      updatedLUTs[index].name = fileName
      didChange = true
    }

    guard didChange else { return }
    do {
      try persist(luts: updatedLUTs, linkedFolders: linkedFolders)
      luts = updatedLUTs
    } catch {
      assertionFailure("Failed to migrate linked LUT display names: \(error)")
    }
  }

  // MARK: - Folder observation

  private func installFolderPresenters(
    resolvedDirectories: [String: URL]
  ) {
    removeAllFolderPresenters()

    for (folderID, directoryURL) in resolvedDirectories {
      guard let presenter = LUTFolderPresenter(
        folderID: folderID,
        directoryURL: directoryURL,
        onChange: { [weak self] in
          Task { @MainActor in
            self?.schedulePresenterRefresh()
          }
        }
      ) else {
        continue
      }
      folderPresenters[folderID] = presenter
      NSFileCoordinator.addFilePresenter(presenter)
    }
  }

  private func schedulePresenterRefresh() {
    guard isLinkedFolderObservationActive else { return }
    presenterRefreshTask?.cancel()
    presenterRefreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard
        Task.isCancelled == false,
        self?.isLinkedFolderObservationActive == true
      else {
        return
      }
      await self?.refreshLinkedFolders()
    }
  }

  private func removeFolderPresenter(folderID: String) {
    guard let presenter = folderPresenters.removeValue(forKey: folderID) else {
      return
    }
    NSFileCoordinator.removeFilePresenter(presenter)
    presenter.stopAccessingPresentedItem()
  }

  private func removeAllFolderPresenters() {
    let folderIDs = Array(folderPresenters.keys)
    for folderID in folderIDs {
      removeFolderPresenter(folderID: folderID)
    }
  }

  /// Rebuilds the nonpersisted hierarchy consumed by the library and editor UI.
  private func rebuildOrganization() {
    let linkedFolderIDs = Set(linkedFolders.map(\.id))
    importedLUTs = luts.filter { lut in
      guard let folderID = lut.linkedFolderOrigin?.folderID else {
        return true
      }
      return linkedFolderIDs.contains(folderID) == false
    }
    linkedFolderCollections = linkedFolders.map { folder in
      LUTFolderCollection.make(folder: folder, luts: luts)
    }
  }

  // MARK: - Persistence

  /// The single atomic payload for LUT metadata and linked-folder bookmarks.
  private struct PersistedLibrary: Codable {
    var luts: [LUT]
    var linkedFolders: [LUTFolderLink]
  }

  /// The pre-Files-only payload retained solely to preserve user imports while
  /// discarding former app-provided LUT records during an in-place upgrade.
  private struct LegacyPersistedLibrary: Decodable {
    var luts: [LegacyLUT]
    var linkedFolders: [LUTFolderLink]
  }

  /// A LUT record from the schema that could point into either Application
  /// Support or the application bundle.
  private struct LegacyLUT: Decodable {

    enum Source: Decodable {
      case imported(fileName: String)
      case bundled(resource: String, ext: String)
    }

    var id: String
    var name: String
    var format: LUT.Format
    var dimension: Int
    var source: Source
    var linkedFolderOrigin: LUT.LinkedFolderOrigin?

    /// Converts only user-sourced files into the current Files-only model.
    var migratedValue: LUT? {
      guard case .imported(let fileName) = source else {
        return nil
      }
      return LUT(
        id: id,
        name: name,
        format: format,
        dimension: dimension,
        storedFileName: fileName,
        linkedFolderOrigin: linkedFolderOrigin
      )
    }
  }

  private var storageDirectory: URL {
    applicationSupport.appendingPathComponent("LUTs", isDirectory: true)
  }

  private var syncStagingDirectory: URL {
    applicationSupport.appendingPathComponent(
      "LUTSyncStaging",
      isDirectory: true
    )
  }

  private var indexURL: URL {
    applicationSupport.appendingPathComponent("lut-library.json")
  }

  private var legacyIndexURL: URL {
    applicationSupport.appendingPathComponent("luts.json")
  }

  private var applicationSupport: URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  private func createStorageDirectoryIfNeeded() throws {
    try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
  }

  private func load() {
    if let data = try? Data(contentsOf: indexURL),
       let decoded = try? JSONDecoder().decode(PersistedLibrary.self, from: data) {
      luts = decoded.luts
      linkedFolders = decoded.linkedFolders
      return
    }

    if let data = try? Data(contentsOf: indexURL),
       let decoded = try? JSONDecoder().decode(
         LegacyPersistedLibrary.self,
         from: data
       ) {
      luts = decoded.luts.compactMap(\.migratedValue)
      linkedFolders = decoded.linkedFolders
      persistMigratedLibrary()
      return
    }

    // Migrate the original LUT-only index on the first subsequent write.
    if let data = try? Data(contentsOf: legacyIndexURL),
       let decoded = try? JSONDecoder().decode([LegacyLUT].self, from: data) {
      luts = decoded.compactMap(\.migratedValue)
      persistMigratedLibrary()
    }
  }

  /// Makes legacy starter removal durable without sacrificing valid imports.
  private func persistMigratedLibrary() {
    do {
      try persist(luts: luts, linkedFolders: linkedFolders)
    } catch {
      assertionFailure("Failed to migrate the Files-only LUT library: \(error)")
    }
  }

  private func persist(
    luts: [LUT],
    linkedFolders: [LUTFolderLink]
  ) throws {
    try fileManager.createDirectory(
      at: applicationSupport,
      withIntermediateDirectories: true
    )
    let payload = PersistedLibrary(luts: luts, linkedFolders: linkedFolders)
    let data = try JSONEncoder().encode(payload)
    try data.write(to: indexURL, options: .atomic)
  }
}
