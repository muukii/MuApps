import JournalVault
import MuColor
import SwiftUI
import VariableBlur

/// Display value consumed by saved vault card components.
///
/// This is intentionally smaller than the vault store row graph. Feature code
/// owns persistence, editing, deletion, and tree traversal; `AppUIComponents`
/// only needs the stable values required to draw a saved card.
public struct VaultSavedEntryCardModel: Identifiable, Hashable {
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
}

/// Saved media reference needed by saved vault card components.
public struct VaultSavedEntryAttachmentModel: Hashable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let thumbnail: Data?
  public let suggestionMediaFileURLsByResourceID: [UUID: URL]

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    thumbnail: Data?,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.thumbnail = thumbnail
    self.suggestionMediaFileURLsByResourceID = suggestionMediaFileURLsByResourceID
  }
}

/// Saved vault card as it appears in Journal surfaces.
///
/// `CardSurface` provides the shared paper chrome while this component owns the
/// saved-card preview body and timestamp. `SavedListView` stays responsible for
/// reading vault data, stack affordances, and edit/delete mutations.
public struct VaultSavedEntryTile: View {

  let entry: VaultSavedEntryCardModel
  let childCount: Int

  public init(
    entry: VaultSavedEntryCardModel,
    childCount: Int
  ) {
    self.entry = entry
    self.childCount = childCount
  }

  public var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 12) {
//        VaultSavedEntryCardHeader(
//          kind: entry.kind,
//          childCount: childCount,
//          timestamp: nil,
//          isEditingDisabled: false,
//          isDeletingDisabled: false,
//          onEdit: nil,
//          onDelete: nil
//        )

        CardPreviewContent(
          payload: entry.previewPayload,
          presentation: .savedSummary
        )

      }
      .frame(maxHeight: .infinity)
      .overlay(alignment: .bottom) {

        Text(entry.createdAt, format: .dateTime.hour().minute())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
          .padding()
          .frame(maxWidth: .infinity)
          .backgroundStyle(.thinMaterial)
      }
    }
  }
}

/// Full saved vault card shown from the saved-entry detail screen.
public struct VaultSavedEntryDetailCard: View {

  let entry: VaultSavedEntryCardModel
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let onEdit: @MainActor () -> Void
  let onDelete: @MainActor () -> Void

  public init(
    entry: VaultSavedEntryCardModel,
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
    CardSurface {
      VStack(alignment: .leading, spacing: 16) {
        VaultSavedEntryCardHeader(
          kind: entry.kind,
          childCount: 0,
          timestamp: entry.createdAt,
          isEditingDisabled: isEditingDisabled,
          isDeletingDisabled: isDeletingDisabled,
          onEdit: onEdit,
          onDelete: onDelete
        )

        CardPreviewContent(
          payload: entry.previewPayload,
          presentation: .savedDetail
        )

        Spacer(minLength: 0)

        VaultSavedEntryMetadata(entry: entry)
      }
    }
  }
}

private struct VaultSavedEntryCardHeader: View {

  let kind: JournalVault.Card.Kind
  let childCount: Int
  let timestamp: Date?
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let onEdit: (@MainActor () -> Void)?
  let onDelete: (@MainActor () -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: kind.vaultListSymbolName)
      Text(kind.vaultListDisplayTitle)
      Spacer(minLength: 0)
      if childCount > 0 {
        Label {
          Text(childCount + 1, format: .number)
        } icon: {
          Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(
          String.localizedStringWithFormat(
            NSLocalizedString("%d cards", comment: "Accessibility label for the number of cards in a saved thread."),
            childCount + 1
          )
        )
      }
      if let timestamp {
        Text(timestamp, format: .dateTime.month().day().hour().minute())
      }
      if let onEdit {
        Button {
          onEdit()
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .disabled(isEditingDisabled)
        .accessibilityLabel("Edit Card")
      }
      if let onDelete {
        Button(role: .destructive) {
          onDelete()
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .disabled(isDeletingDisabled)
        .accessibilityLabel("Delete Card")
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.70))
  }
}

private struct VaultSavedEntryMetadata: View {

  let entry: VaultSavedEntryCardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(entry.updatedAt, format: .dateTime.month().day().hour().minute())
      } icon: {
        Image(systemName: "clock.arrow.circlepath")
      }

      if let location = entry.location {
        Label {
          Text(
            "\(location.latitude.formatted(.number.precision(.fractionLength(4)))), \(location.longitude.formatted(.number.precision(.fractionLength(4))))"
          )
        } icon: {
          Image(systemName: "location")
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.62))
  }
}

private extension VaultSavedEntryCardModel {

  var previewPayload: CardPreviewPayload {
    CardPreviewPayload(
      kind: kind,
      body: body,
      attachment: attachment?.previewAttachment
    )
  }
}

private extension VaultSavedEntryAttachmentModel {

  var previewAttachment: CardPreviewAttachment {
    CardPreviewAttachment(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: pairedVideoFileURL,
      thumbnailData: thumbnail,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }
}

public extension JournalVault.Card.Kind {

  var vaultListDisplayTitle: LocalizedStringResource {
    switch self {
    case .text:
      "Text"
    case .link:
      "Link"
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
      "Card"
    @unknown default:
      "Card"
    }
  }

  var vaultListSymbolName: String {
    switch self {
    case .text:
      "text.alignleft"
    case .link:
      "link"
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
  PrimaryContainer(theme: .default) {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(VaultSavedEntryCardPreviewFixtures.day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
          .font(.headline)
          .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
          ],
          spacing: 16
        ) {
          ForEach(VaultSavedEntryCardPreviewFixtures.examples) { example in
            VaultSavedEntryTile(
              entry: example.entry,
              childCount: example.childCount
            )
          }
        }
      }
      .padding(16)
    }
    .background(.background)
  }
}

#Preview("Vault Saved Entry Detail Card") {
  PrimaryContainer(theme: .default) {
    ScrollView {
      VaultSavedEntryDetailCard(
        entry: VaultSavedEntryCardPreviewFixtures.examples[1].entry,
        isEditingDisabled: false,
        isDeletingDisabled: false,
        onEdit: {},
        onDelete: {}
      )
      .frame(maxWidth: 520)
      .padding(16)
    }
    .background(.background)
  }
}

/// Preview-only snapshot for one saved-card tile.
///
/// The production list gets the same value shape from `VaultSavedEntryReader`.
/// Keeping the fixture at the display-model boundary lets the Preview render
/// the real card components without opening a vault store.
private struct VaultSavedEntryCardPreviewExample: Identifiable {
  var id: UUID { entry.id }

  let entry: VaultSavedEntryCardModel
  let childCount: Int
}

@MainActor
private enum VaultSavedEntryCardPreviewFixtures {

  static let day = Date(timeIntervalSinceReferenceDate: 789_004_800)

  static let examples: [VaultSavedEntryCardPreviewExample] = [
    VaultSavedEntryCardPreviewExample(
      entry: entry(
        kind: .text,
        body: "Small notes should still read like the same card in the real list.",
        createdAt: day.addingTimeInterval(-120)
      ),
      childCount: 0
    ),
    VaultSavedEntryCardPreviewExample(
      entry: entry(
        kind: .link,
        body: "https://www.apple.com",
        createdAt: day.addingTimeInterval(-460)
      ),
      childCount: 2
    ),
    VaultSavedEntryCardPreviewExample(
      entry: entry(
        kind: .photo,
        body: "",
        createdAt: day.addingTimeInterval(-1_200)
      ),
      childCount: 0
    ),
    VaultSavedEntryCardPreviewExample(
      entry: entry(
        kind: .audio,
        body: "",
        createdAt: day.addingTimeInterval(-1_680)
      ),
      childCount: 1
    ),
  ]

  private static func entry(
    kind: JournalVault.Card.Kind,
    body: String,
    createdAt: Date
  ) -> VaultSavedEntryCardModel {
    VaultSavedEntryCardModel(
      id: UUID(),
      kind: kind,
      body: body,
      createdAt: createdAt,
      updatedAt: createdAt,
      location: nil,
      attachment: nil
    )
  }
}
