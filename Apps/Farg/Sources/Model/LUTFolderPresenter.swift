//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// Foreground-only presenter that turns coordinated directory mutations into a
/// debounced linked-folder rescan.
///
/// The library owns registration and must unregister this presenter before the
/// app enters the background, as required by `NSFilePresenter` on iOS.
///
/// `nonisolated` is required because Foundation queries the presenter from its
/// private File Coordination queues, regardless of the registration caller.
nonisolated final class LUTFolderPresenter:
  NSObject,
  NSFilePresenter,
  @unchecked Sendable
{

  let folderID: String
  let presentedItemURL: URL?
  let presentedItemOperationQueue: OperationQueue

  private let onChange: @Sendable () -> Void
  private let accessStateLock = NSLock()
  private var isAccessingPresentedItem: Bool

  init?(
    folderID: String,
    directoryURL: URL,
    onChange: @escaping @Sendable () -> Void
  ) {
    guard directoryURL.startAccessingSecurityScopedResource() else {
      return nil
    }

    let operationQueue = OperationQueue()
    operationQueue.name = "Farg.LUTFolderPresenter.\(folderID)"
    operationQueue.maxConcurrentOperationCount = 1
    operationQueue.qualityOfService = .utility

    self.folderID = folderID
    self.presentedItemURL = directoryURL
    self.presentedItemOperationQueue = operationQueue
    self.onChange = onChange
    self.isAccessingPresentedItem = true
    super.init()
  }

  func stopAccessingPresentedItem() {
    let shouldStop = accessStateLock.withLock {
      guard isAccessingPresentedItem else { return false }
      isAccessingPresentedItem = false
      return true
    }
    if shouldStop {
      presentedItemURL?.stopAccessingSecurityScopedResource()
    }
  }

  func presentedItemDidChange() {
    onChange()
  }

  func presentedSubitemDidAppear(at url: URL) {
    onChange()
  }

  func presentedSubitemDidChange(at url: URL) {
    onChange()
  }

  func presentedSubitem(
    at oldURL: URL,
    didMoveTo newURL: URL
  ) {
    onChange()
  }

  func accommodatePresentedSubitemDeletion(
    at url: URL,
    completionHandler: @escaping @Sendable ((any Error)?) -> Void
  ) {
    onChange()
    completionHandler(nil)
  }
}
