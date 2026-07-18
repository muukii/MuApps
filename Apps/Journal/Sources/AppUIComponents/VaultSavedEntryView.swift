import JournalVault
import MapKit
import MuColor
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// Display value consumed by saved-entry components.
///
/// This is intentionally smaller than the vault store row graph. Feature code
/// owns persistence, editing, deletion, and tree traversal; `AppUIComponents`
/// only needs the stable values required to draw saved authored content.
public struct VaultSavedEntryModel: Identifiable, Hashable {
  public let id: UUID
  public let kind: JournalVault.Card.Kind
  public let body: String
  public let createdAt: Date
  public let updatedAt: Date
  public let location: JournalVault.Coordinate?
  public let attachment: VaultSavedEntryAttachmentModel?

  public init(
    id: UUID,
    kind: JournalVault.Card.Kind,
    body: String,
    createdAt: Date,
    updatedAt: Date,
    location: JournalVault.Coordinate?,
    attachment: VaultSavedEntryAttachmentModel?
  ) {
    self.id = id
    self.kind = kind
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.location = location
    self.attachment = attachment
  }

  /// Authored content projected away from the persistence row graph.
  public var content: EntryContent {
    EntryContent(
      kind: kind,
      body: body,
      attachment: attachment?.contentAttachment
    )
  }
}

/// Saved file-backed attachment values needed by saved-entry components.
public struct VaultSavedEntryAttachmentModel: Hashable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let fileRevision: Int
  public let thumbnail: Data?
  public let pixelSize: CGSize?
  public let contentType: String?
  public let byteSize: Int?
  public let suggestionMediaFileURLsByResourceID: [UUID: URL]

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnail: Data?,
    pixelSize: CGSize? = nil,
    contentType: String? = nil,
    byteSize: Int? = nil,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.fileRevision = fileRevision
    self.thumbnail = thumbnail
    self.pixelSize = pixelSize
    self.contentType = contentType
    self.byteSize = byteSize
    self.suggestionMediaFileURLsByResourceID = suggestionMediaFileURLsByResourceID
  }
}

/// A finite placement boundary for authored content in the saved-entry grid.
///
/// The transparent square owns only grid geometry. Content still owns its
/// typography and media treatment through `.savedGrid`; the centered overlay
/// prevents asynchronous media decoding from changing row height, while the
/// outer boundary keeps every content type inside its column.
public struct VaultSavedEntryGridCell: View {

  private let content: EntryContent

  public init(content: EntryContent) {
    self.content = content
  }

  public var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        EntryContentView(
          content: content,
          style: .savedGrid
        )
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .center
        )
      }
      .clipped()
      .contentShape(Rectangle())
  }
}

/// Standalone authored content and its record metadata in the detail screen.
///
/// Unlike a compact tile, the detail row has no shared card silhouette. Each
/// authored format owns its natural height and media aspect ratio; record
/// metadata and mutation controls remain a separate footer below it.
public struct VaultSavedEntryDetailRow: View {

  let entry: VaultSavedEntryModel
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let onEdit: @MainActor () -> Void
  let onDelete: @MainActor () -> Void

  public init(
    entry: VaultSavedEntryModel,
    isEditingDisabled: Bool,
    isDeletingDisabled: Bool,
    onEdit: @escaping @MainActor () -> Void,
    onDelete: @escaping @MainActor () -> Void
  ) {
    self.entry = entry
    self.isEditingDisabled = isEditingDisabled
    self.isDeletingDisabled = isDeletingDisabled
    self.onEdit = onEdit
    self.onDelete = onDelete
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      EntryContentView(content: entry.content, style: .detail)
        .frame(maxWidth: .infinity, alignment: .center)
        .foregroundStyle(.appOnPrimaryContainer)

      if let location = entry.location {
        VaultSavedEntryLocationMap(location: location)
          .frame(maxWidth: 640)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 8)
      }

      VaultSavedEntryDetailMetadata(
        kind: entry.kind,
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt,
        isEditingDisabled: isEditingDisabled,
        isDeletingDisabled: isDeletingDisabled,
        onEdit: onEdit,
        onDelete: onDelete
      )
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 8)
    }
  }
}

/// A compact geographic context strip for the location attached to a card.
///
/// The map is intentionally static so vertical detail scrolling remains the
/// primary gesture. Its camera keeps enough surrounding streets visible to make
/// the recorded point recognizable without turning the row into a map screen.
private struct VaultSavedEntryLocationMap: View {

  let location: JournalVault.Coordinate

  var body: some View {
    ZStack {
      Map(
        initialPosition: .region(region),
        interactionModes: []
      )
      .mapStyle(.standard(elevation: .flat))

      Image(systemName: "mappin")
        .font(.body.weight(.semibold))
        .foregroundStyle(.appOnPrimaryContainer)
        .padding(9)
        .background(.appPrimaryContainer, in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
    .frame(height: 112)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(.appOnPrimaryContainer.opacity(0.12), lineWidth: 1)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Location")
    .accessibilityValue(formattedCoordinate)
  }

  private var region: MKCoordinateRegion {
    MKCoordinateRegion(
      center: location.clCoordinate,
      latitudinalMeters: 1_200,
      longitudinalMeters: 1_200
    )
  }

  private var formattedCoordinate: String {
    "\(location.latitude.formatted(.number.precision(.fractionLength(4)))), \(location.longitude.formatted(.number.precision(.fractionLength(4))))"
  }
}

/// Record metadata and mutation controls displayed below authored detail content.
private struct VaultSavedEntryDetailMetadata: View {

  let kind: JournalVault.Card.Kind
  let createdAt: Date
  let updatedAt: Date
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let onEdit: @MainActor () -> Void
  let onDelete: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label {
          Text(kind.vaultListDisplayTitle)
        } icon: {
          Image(systemName: kind.vaultListSymbolName)
        }

        Spacer(minLength: 0)

        Button {
          onEdit()
        } label: {
          Image(systemName: "square.and.pencil")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEditingDisabled)
        .accessibilityLabel("Edit Entry")

        Button(role: .destructive) {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .disabled(isDeletingDisabled)
        .accessibilityLabel("Delete Entry")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))

      Label {
        Text(createdAt, format: .dateTime.month().day().year().hour().minute())
      } icon: {
        Image(systemName: "calendar")
      }
      .accessibilityLabel("Created")
      .accessibilityValue(
        Text(createdAt, format: .dateTime.month().day().year().hour().minute())
      )

      if updatedAt != createdAt {
        Label {
          Text(updatedAt, format: .dateTime.month().day().year().hour().minute())
        } icon: {
          Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Updated")
        .accessibilityValue(
          Text(updatedAt, format: .dateTime.month().day().year().hour().minute())
        )
      }

    }
    .font(.caption)
    .foregroundStyle(.appOnPrimaryContainer.opacity(0.58))
  }
}

extension VaultSavedEntryAttachmentModel {

  fileprivate var contentAttachment: EntryContentAttachment {
    EntryContentAttachment(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: pairedVideoFileURL,
      fileRevision: fileRevision,
      thumbnailData: thumbnail,
      pixelSize: pixelSize,
      contentType: contentType,
      byteSize: byteSize,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }
}

extension JournalVault.Card.Kind {

  public var vaultListDisplayTitle: LocalizedStringResource {
    switch self {
    case .text:
      "Text"
    case .link:
      "Link"
    case .file:
      "File"
    case .photo:
      "Photo"
    case .video:
      "Video"
    case .livePhoto:
      "Live Photo"
    case .audio:
      "Audio"
    case .suggestion:
      "Suggestion"
    case .doodle:
      "Doodle"
    case .bauhaus:
      "Bauhaus"
    case .unknown:
      "Entry"
    @unknown default:
      "Entry"
    }
  }

  public var vaultListSymbolName: String {
    switch self {
    case .text:
      "text.alignleft"
    case .link:
      "link"
    case .file:
      "doc"
    case .photo:
      "photo"
    case .video:
      "video"
    case .livePhoto:
      "livephoto"
    case .audio:
      "waveform"
    case .suggestion:
      "sparkles"
    case .doodle:
      "scribble"
    case .bauhaus:
      "square.grid.3x3"
    case .unknown:
      "questionmark.square.dashed"
    @unknown default:
      "questionmark.square.dashed"
    }
  }
}

#Preview("Vault Saved Entry Tiles") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          VaultSavedEntryPreviewFixtures.day,
          format: .dateTime.weekday(.abbreviated).month(.wide).day().year()
        )
        .font(.headline)
        .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
          ],
          spacing: 16
        ) {
          ForEach(VaultSavedEntryPreviewFixtures.examples) { example in
            VaultSavedEntryGridCell(content: example.entry.content)
          }
        }
      }
      .padding(16)
    }
    .background(.background)
  }
}

#Preview("Vault Saved Entry Detail Row") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VaultSavedEntryDetailRow(
        entry: VaultSavedEntryPreviewFixtures.detailEntry,
        isEditingDisabled: false,
        isDeletingDisabled: false,
        onEdit: {},
        onDelete: {}
      )
      .frame(maxWidth: 720)
      .padding(16)
    }
    .background(.background)
  }
}

#Preview("Vault Saved Entry Detail Media Ratios") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      LazyVStack(spacing: 40) {
        ForEach(VaultSavedEntryPreviewFixtures.detailMediaEntries) { entry in
          VaultSavedEntryDetailRow(
            entry: entry,
            isEditingDisabled: false,
            isDeletingDisabled: false,
            onEdit: {},
            onDelete: {}
          )
          .frame(maxWidth: 720)
        }
      }
      .padding(16)
    }
    .background(.background)
  }
}

#Preview("Vault Saved Entry Portrait Video Detail") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VaultSavedEntryDetailRow(
        entry: VaultSavedEntryPreviewFixtures.portraitVideoEntry,
        isEditingDisabled: false,
        isDeletingDisabled: false,
        onEdit: {},
        onDelete: {}
      )
      .frame(maxWidth: 300)
      .frame(maxWidth: .infinity)
      .padding(16)
    }
    .background(.background)
  }
}

/// Preview-only example for one saved-entry grid cell.
///
/// The production list derives this value shape from live SwiftData models.
/// Keeping the fixture at the display-model boundary lets the Preview render
/// the real saved-entry components without opening a vault store.
private struct VaultSavedEntryPreviewExample: Identifiable {
  var id: UUID { entry.id }

  let entry: VaultSavedEntryModel
}

@MainActor
private enum VaultSavedEntryPreviewFixtures {

  static let day = Date(timeIntervalSinceReferenceDate: 789_004_800)

  static let detailEntry = entry(
    kind: .text,
    body:
      "Small notes can use the width they need. The detail view drops the paper frame and lets the authored content define its own height.",
    createdAt: day.addingTimeInterval(-7_200),
    updatedAt: day.addingTimeInterval(-1_800),
    location: JournalVault.Coordinate(
      latitude: 35.6812,
      longitude: 139.7671
    )
  )

  static let landscapePhotoEntry = entry(
    kind: .photo,
    body: "",
    createdAt: day.addingTimeInterval(-10_800),
    attachment: mediaAttachment(
      kind: .photo,
      pixelSize: CGSize(width: 640, height: 360),
      title: "LANDSCAPE"
    )
  )

  static let portraitVideoEntry = entry(
    kind: .video,
    body: "",
    createdAt: day.addingTimeInterval(-14_400),
    attachment: mediaAttachment(
      kind: .video,
      pixelSize: CGSize(width: 270, height: 480),
      title: "PORTRAIT"
    )
  )

  static let squarePhotoEntry = entry(
    kind: .photo,
    body: "",
    createdAt: day.addingTimeInterval(-12_600),
    attachment: mediaAttachment(
      kind: .photo,
      pixelSize: CGSize(width: 360, height: 360),
      title: "SQUARE"
    )
  )

  static let detailMediaEntries: [VaultSavedEntryModel] = [
    landscapePhotoEntry,
    portraitVideoEntry,
  ]

  static let examples: [VaultSavedEntryPreviewExample] = [
    VaultSavedEntryPreviewExample(
      entry: entry(
        kind: .text,
        body: "Small notes should keep their own shape in the real list.",
        createdAt: day.addingTimeInterval(-120)
      )
    ),
    VaultSavedEntryPreviewExample(
      entry: squarePhotoEntry
    ),
    VaultSavedEntryPreviewExample(
      entry: entry(
        kind: .link,
        body: "https://www.apple.com",
        createdAt: day.addingTimeInterval(-460)
      )
    ),
    VaultSavedEntryPreviewExample(entry: landscapePhotoEntry),
    VaultSavedEntryPreviewExample(entry: portraitVideoEntry),
    VaultSavedEntryPreviewExample(
      entry: entry(
        kind: .audio,
        body: "",
        createdAt: day.addingTimeInterval(-1_680)
      )
    ),
  ]

  private static func entry(
    kind: JournalVault.Card.Kind,
    body: String,
    createdAt: Date,
    updatedAt: Date? = nil,
    location: JournalVault.Coordinate? = nil,
    attachment: VaultSavedEntryAttachmentModel? = nil
  ) -> VaultSavedEntryModel {
    VaultSavedEntryModel(
      id: UUID(),
      kind: kind,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt,
      location: location,
      attachment: attachment
    )
  }

  private static func mediaAttachment(
    kind: JournalVault.Attachment.Kind,
    pixelSize: CGSize,
    title: String
  ) -> VaultSavedEntryAttachmentModel {
    VaultSavedEntryAttachmentModel(
      kind: kind,
      fileURL: URL(fileURLWithPath: "/preview/\(title.lowercased())"),
      thumbnail: previewImageData(pixelSize: pixelSize, title: title),
      pixelSize: pixelSize
    )
  }

  /// Produces an edge-marked raster whose four corners expose accidental crop.
  private static func previewImageData(
    pixelSize: CGSize,
    title: String
  ) -> Data? {
    #if canImport(UIKit)
      let markerInset = max(8, min(pixelSize.width, pixelSize.height) * 0.04)
      let renderer = ImageRenderer(
        content: ZStack {
          LinearGradient(
            colors: [.pink, .orange, .blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Text(title)
            .font(
              .system(
                size: min(pixelSize.width, pixelSize.height) * 0.09,
                weight: .black,
                design: .rounded
              )
            )
            .foregroundStyle(.white)

          VStack {
            HStack {
              Text("TL")
              Spacer()
              Text("TR")
            }
            Spacer()
            HStack {
              Text("BL")
              Spacer()
              Text("BR")
            }
          }
          .font(.system(size: 22, weight: .black, design: .rounded))
          .foregroundStyle(.white)
          .padding(markerInset)
        }
        .frame(width: pixelSize.width, height: pixelSize.height)
      )
      renderer.scale = 1
      return renderer.uiImage?.pngData()
    #else
      return nil
    #endif
  }
}
