import Foundation
import SwiftData
import UniformTypeIdentifiers

/// One file-backed resource that belongs to an `Attachment`.
///
/// `Attachment` models the user-visible item; resources model the concrete
/// files that item needs. A Live Photo, for example, can keep one logical
/// attachment while storing separate still-image and paired-video resources.
///
/// The row stores domain metadata and a local file identity. CloudKit's
/// `CKAsset` is a transport detail owned by the sync mapper, not a durable
/// domain reference.
@Model
public final class AttachmentResource {

  @Attribute(.unique)
  public var id: UUID

  /// Owning logical attachment.
  public var attachmentID: UUID

  /// Raw role string as stored and synced. Read through `role`.
  public var roleRawValue: String

  /// Size of the local file in bytes, recorded when the file is staged.
  public var byteSize: Int

  /// Uniform Type Identifier, MIME type, or other stable content-type string.
  public var contentType: String?

  /// Pixel width for image/video resources when known.
  public var pixelWidth: Int?

  /// Pixel height for image/video resources when known.
  public var pixelHeight: Int?

  /// Duration in seconds for video/audio resources when known.
  public var duration: Double?

  /// Whether the resource contains HDR media.
  public var isHDR: Bool

  /// Color space name, when the media pipeline can determine it.
  public var colorSpaceName: String?

  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    attachmentID: UUID,
    role: Role,
    byteSize: Int = 0,
    contentType: String? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil,
    duration: Double? = nil,
    isHDR: Bool = false,
    colorSpaceName: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.attachmentID = attachmentID
    self.roleRawValue = role.rawValue
    self.byteSize = byteSize
    self.contentType = contentType
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.duration = duration
    self.isHDR = isHDR
    self.colorSpaceName = colorSpaceName
    self.createdAt = createdAt
  }
}

// MARK: - Role

extension AttachmentResource {

  /// Meaning of a resource inside its logical attachment.
  ///
  /// Raw values are stable CloudKit payload values. Additive roles let newer
  /// builds attach richer media without changing the parent `Attachment` shape.
  public enum Role: String, Codable, Sendable, CaseIterable, Hashable {
    /// Original still image for a photo attachment.
    case originalImage

    /// Still-image component of a Live Photo attachment.
    case stillImage

    /// Paired movie component of a Live Photo attachment.
    case pairedVideo

    /// Original video file for a video attachment.
    case originalVideo

    /// JSON authored value for vector/generated cards such as Doodle/Bauhaus.
    case authoredJSON

    /// Still image, artwork, poster, or icon copied from a selected suggestion.
    case suggestionImage

    /// Video file copied from a selected suggestion.
    case suggestionVideo

    /// Audio recording file.
    case audio

    /// A role this build does not recognize — synced from a newer app version.
    case unknown
  }

  /// Typed view over `roleRawValue`. Unrecognized raw values read as `.unknown`.
  public var role: Role {
    get { Role(rawValue: roleRawValue) ?? .unknown }
    set { roleRawValue = newValue.rawValue }
  }

  /// File name on disk.
  ///
  /// The CloudKit record name remains `id.uuidString`; the local asset file
  /// keeps a content-type-derived extension so file URL consumers such as
  /// AVFoundation can infer the media container reliably.
  public var fileName: String {
    guard let pathExtension else {
      return id.uuidString
    }

    return "\(id.uuidString).\(pathExtension)"
  }

  private var pathExtension: String? {
    guard let contentType else {
      return nil
    }

    if let identifierType = UTType(contentType),
      let filenameExtension = identifierType.preferredFilenameExtension
    {
      return filenameExtension
    }

    if let mimeType = UTType(mimeType: contentType),
      let filenameExtension = mimeType.preferredFilenameExtension
    {
      return filenameExtension
    }

    return nil
  }
}
