import Foundation

/// Record types the vault sync layer stores in a vault's CloudKit zone.
///
/// Raw values are the CloudKit record type names — changing one is a server
/// schema migration for every record already uploaded.
public enum VaultRecordType: String, Sendable, CaseIterable, Hashable {
  case vaultInfo = "VaultInfo"
  case card = "Card"
  case cardEdge = "CardEdge"
  case attachment = "Attachment"
  case attachmentResource = "AttachmentResource"
  case activity = "VaultActivity"
  case notificationPulse = "VaultNotificationPulse"
}
