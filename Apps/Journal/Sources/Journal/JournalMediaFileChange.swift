import Foundation

/// Process-local signal that a persisted attachment file changed on disk.
///
/// SwiftData/CloudKit mirroring delivers `Card` and `Attachment` rows
/// independently from `MediaSyncEngine`'s CKAsset files. A view can therefore
/// see the SwiftData record before the local media file exists. This notification
/// lets media views retry their file load when the custom media sync later writes
/// or deletes the file without making `MediaSyncEngine` depend on SwiftData.
enum JournalMediaFileChange {

  nonisolated static let notificationName = Notification.Name(
    "app.muukii.journal.media-file-did-change"
  )

  nonisolated private static let attachmentIDKey = "attachmentID"

  nonisolated static func post(attachmentID: UUID?) {
    var userInfo: [String: Any] = [:]
    if let attachmentID {
      userInfo[attachmentIDKey] = attachmentID
    }

    NotificationCenter.default.post(
      name: notificationName,
      object: nil,
      userInfo: userInfo
    )
  }

  nonisolated static func attachmentID(from notification: Notification) -> UUID? {
    notification.userInfo?[attachmentIDKey] as? UUID
  }
}

/// Process-local signal that the custom media sync engine's diagnostic state changed.
///
/// Settings uses this to refresh pending counts, last activity, and failures
/// without making `MediaSyncEngine` an observable main-actor object.
enum JournalMediaSyncStatusChange {

  nonisolated static let notificationName = Notification.Name(
    "app.muukii.journal.media-sync-status-did-change"
  )

  nonisolated static func post() {
    NotificationCenter.default.post(name: notificationName, object: nil)
  }
}
