import Foundation

/// Posted when the sync layer changes attachment *files* on disk.
///
/// Attachment bytes arrive after (or independently of) their SwiftData rows —
/// an `Attachment` row can be imported before its `CKAsset` file lands. Row
/// changes are observed through SwiftData; views showing media listen for this
/// notification to retry loading the file.
public enum VaultMediaFileChange {

  public static let name = Notification.Name("JournalVault.mediaFileDidChange")

  /// `userInfo` key carrying the `VaultID`.
  public static let vaultIDKey = "vaultID"

  /// `userInfo` key carrying the changed attachment IDs (`[UUID]`).
  public static let attachmentIDsKey = "attachmentIDs"

  public static func post(vaultID: VaultID, attachmentIDs: [UUID]) {
    NotificationCenter.default.post(
      name: name,
      object: nil,
      userInfo: [
        vaultIDKey: vaultID,
        attachmentIDsKey: attachmentIDs,
      ]
    )
  }
}
