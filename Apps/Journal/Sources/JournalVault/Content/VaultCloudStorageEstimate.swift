import Foundation
import SwiftData

/// A local estimate of the CloudKit payload Journal owns for one vault.
///
/// CloudKit does not expose the user's current iCloud usage or the exact
/// server-side byte cost of records. This value is therefore intentionally
/// narrower: it sums the authored payload bytes Journal stores in records and
/// CKAssets, while keeping record overhead as counts.
public struct VaultCloudStorageEstimate: Equatable, Sendable {

  /// Number of `VaultInfo` records in this vault.
  public var vaultInfoCount: Int

  /// Number of `Card` records in this vault.
  public var cardCount: Int

  /// Number of `CardEdge` records in this vault.
  public var cardEdgeCount: Int

  /// Number of `Attachment` records in this vault.
  public var attachmentCount: Int

  /// Number of `AttachmentResource` records in this vault.
  public var attachmentResourceCount: Int

  /// Number of immutable `VaultActivity` history records in this vault.
  public var activityCount: Int

  /// Number of mutable `VaultNotificationPulse` records in this vault.
  ///
  /// A valid vault has zero or one. Personal vaults may remain at zero because
  /// Pulse is created only while another participant exists.
  public var notificationPulseCount: Int

  /// UTF-8 bytes stored in card body fields, including text and link cards.
  public var cardBodyBytes: Int

  /// Bytes stored in CKAsset-backed attachment files.
  public var mediaBytes: Int

  /// Bytes stored inline as save-time thumbnail fields.
  public var thumbnailBytes: Int

  /// Bytes stored inline as versioned recorded-audio waveform payloads.
  public var waveformBytes: Int

  /// Attachment file bytes grouped by media modality.
  public var mediaBreakdowns: [MediaBreakdown]

  public init(
    vaultInfoCount: Int = 0,
    cardCount: Int = 0,
    cardEdgeCount: Int = 0,
    attachmentCount: Int = 0,
    attachmentResourceCount: Int = 0,
    activityCount: Int = 0,
    notificationPulseCount: Int = 0,
    cardBodyBytes: Int = 0,
    mediaBytes: Int = 0,
    thumbnailBytes: Int = 0,
    waveformBytes: Int = 0,
    mediaBreakdowns: [MediaBreakdown] = []
  ) {
    self.vaultInfoCount = vaultInfoCount
    self.cardCount = cardCount
    self.cardEdgeCount = cardEdgeCount
    self.attachmentCount = attachmentCount
    self.attachmentResourceCount = attachmentResourceCount
    self.activityCount = activityCount
    self.notificationPulseCount = notificationPulseCount
    self.cardBodyBytes = cardBodyBytes
    self.mediaBytes = mediaBytes
    self.thumbnailBytes = thumbnailBytes
    self.waveformBytes = waveformBytes
    self.mediaBreakdowns = mediaBreakdowns
  }

  /// Record rows Journal expects to mirror into the vault's CloudKit zone.
  public var recordCount: Int {
    vaultInfoCount
      + cardCount
      + cardEdgeCount
      + attachmentCount
      + attachmentResourceCount
      + activityCount
      + notificationPulseCount
  }

  /// Inline bytes stored directly on CloudKit records.
  public var inlinePayloadBytes: Int {
    cardBodyBytes + thumbnailBytes + waveformBytes
  }

  /// Authored payload bytes Journal can estimate locally.
  public var estimatedPayloadBytes: Int {
    inlinePayloadBytes + mediaBytes
  }
}

extension VaultCloudStorageEstimate {

  /// CKAsset file bytes for one attachment modality.
  public struct MediaBreakdown: Identifiable, Equatable, Sendable {
    public var kind: Attachment.Kind
    public var count: Int
    public var byteSize: Int

    public init(kind: Attachment.Kind, count: Int, byteSize: Int) {
      self.kind = kind
      self.count = count
      self.byteSize = byteSize
    }

    public var id: Attachment.Kind { kind }
  }
}

extension VaultContentStore {

  /// Builds a local estimate of the CloudKit payload for this vault.
  ///
  /// The result is useful for user-facing storage transparency, but it is not an
  /// iCloud quota API. It excludes CloudKit's server overhead, system fields,
  /// deleted-record history, and data owned by other apps.
  @MainActor
  public func cloudStorageEstimate() throws -> VaultCloudStorageEstimate {
    let context = container.mainContext
    let vaultInfoCount = try context.fetchCount(FetchDescriptor<VaultInfo>())
    let activityCount = try context.fetchCount(FetchDescriptor<VaultActivity>())
    let notificationPulseCount = try context.fetchCount(FetchDescriptor<VaultNotificationPulse>())
    let allEdges = try context.fetch(FetchDescriptor<CardEdge>())
    let activeEdges = allEdges.filter { $0.deletedAt == nil }
    let activeCardIDs = Set(activeEdges.map(\.cardID))
    let logicallyDeletedCardIDs = Set(
      allEdges.lazy
        .filter { $0.deletedAt != nil && activeCardIDs.contains($0.cardID) == false }
        .map(\.cardID)
    )
    let cards = try context.fetch(FetchDescriptor<Card>())
      .filter { logicallyDeletedCardIDs.contains($0.id) == false }
    let allAttachments = try context.fetch(FetchDescriptor<Attachment>())
    let logicallyDeletedAttachmentIDs = Set(
      allAttachments.lazy
        .filter { logicallyDeletedCardIDs.contains($0.cardID) }
        .map(\.id)
    )
    let attachments =
      allAttachments
      .filter { logicallyDeletedAttachmentIDs.contains($0.id) == false }
    let resources = try context.fetch(FetchDescriptor<AttachmentResource>())
      .filter { logicallyDeletedAttachmentIDs.contains($0.attachmentID) == false }
    let attachmentsByID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })

    let cardBodyBytes = cards.reduce(0) { partialResult, card in
      partialResult + card.body.utf8.count
    }

    let thumbnailBytes = attachments.reduce(0) { partialResult, attachment in
      partialResult + (attachment.thumbnail?.count ?? 0)
    }

    let waveformBytes = resources.reduce(0) { partialResult, resource in
      partialResult + (resource.waveformData?.count ?? 0)
    }

    var mediaBytesByKind: [Attachment.Kind: (count: Int, byteSize: Int)] = [:]
    for resource in resources {
      guard let attachment = attachmentsByID[resource.attachmentID] else { continue }
      let byteSize = estimatedMediaByteSize(for: resource)
      let current = mediaBytesByKind[attachment.kind] ?? (count: 0, byteSize: 0)
      mediaBytesByKind[attachment.kind] = (
        count: current.count + 1,
        byteSize: current.byteSize + byteSize
      )
    }

    let mediaBreakdowns = Attachment.Kind.allCases
      .compactMap { kind -> VaultCloudStorageEstimate.MediaBreakdown? in
        guard let value = mediaBytesByKind[kind], value.count > 0 else { return nil }
        return VaultCloudStorageEstimate.MediaBreakdown(
          kind: kind,
          count: value.count,
          byteSize: value.byteSize
        )
      }

    return VaultCloudStorageEstimate(
      vaultInfoCount: vaultInfoCount,
      cardCount: cards.count,
      cardEdgeCount: activeEdges.count,
      attachmentCount: attachments.count,
      attachmentResourceCount: resources.count,
      activityCount: activityCount,
      notificationPulseCount: notificationPulseCount,
      cardBodyBytes: cardBodyBytes,
      mediaBytes: mediaBreakdowns.reduce(0) { $0 + $1.byteSize },
      thumbnailBytes: thumbnailBytes,
      waveformBytes: waveformBytes,
      mediaBreakdowns: mediaBreakdowns
    )
  }

  private func estimatedMediaByteSize(for resource: AttachmentResource) -> Int {
    if resource.byteSize > 0 {
      return resource.byteSize
    }

    let fileURL = fileURL(for: resource)
    return (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}
