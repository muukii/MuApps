import AppIntents
import CaptureBauhaus
import CaptureDoodle
import JournalIntents
import JournalVault
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WidgetKit

// MARK: - Widget

/// Shows the latest card from one configured Journal vault on Home Screen, Lock
/// Screen, and StandBy widget surfaces.
///
/// Each widget instance owns its vault choice through WidgetKit configuration.
/// The timeline provider resolves that choice from `VaultCatalogStore`, then
/// opens only the selected `VaultContentStore` to build a sendable snapshot.
struct LatestNoteWidget: Widget {

  private let kind = JournalWidgetKind.latestNote
  #if os(iOS)
  private let supportedFamilies: [WidgetFamily] = [
    .systemSmall, .systemMedium, .systemLarge,
    .accessoryInline, .accessoryCircular, .accessoryRectangular,
  ]
  #else
  private let supportedFamilies: [WidgetFamily] = [
    .systemSmall, .systemMedium, .systemLarge,
  ]
  #endif

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind,
      intent: LatestNoteWidgetConfiguration.self,
      provider: LatestNoteProvider()
    ) { entry in
      LatestNoteView(entry: entry)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Latest Note")
    .description("Shows the latest card from the vault you choose.")
    .supportedFamilies(supportedFamilies)
  }
}

// MARK: - Configuration

/// Widget configuration for choosing which vault this widget instance reads.
///
/// The parameter is optional so already-placed widgets can keep rendering: when
/// no vault is configured, the provider falls back to the first catalog vault.
struct LatestNoteWidgetConfiguration: WidgetConfigurationIntent {

  static let title: LocalizedStringResource = "Latest Note"
  static let description = IntentDescription("Choose which vault this widget should show.")

  @Parameter(title: "Vault")
  var vault: JournalVaultEntity?

  init() {
    self.vault = nil
  }

  init(vault: JournalVaultEntity?) {
    self.vault = vault
  }
}

// MARK: - Timeline

struct LatestNoteEntry: TimelineEntry {
  let date: Date
  let vault: WidgetVaultSnapshot?
  let note: NoteSnapshot?
}

/// Sendable snapshot of the configured vault used by widget views.
struct WidgetVaultSnapshot: Sendable, Hashable {
  let id: VaultID
  let title: String
  let icon: VaultIcon

  init(descriptor: VaultDescriptor) {
    self.id = descriptor.vaultID
    self.title = Self.displayTitle(for: descriptor.title)
    self.icon = descriptor.icon
  }

  init(id: VaultID, title: String, icon: VaultIcon = .default) {
    self.id = id
    self.title = Self.displayTitle(for: title)
    self.icon = icon
  }

  private static func displayTitle(for title: String) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? String(localized: "Untitled Vault") : trimmedTitle
  }
}

/// A `Sendable`, value-type view of the latest vault `Card`. The widget renders
/// this rather than holding a SwiftData model reference, keeping the timeline
/// entry `Sendable` and the views free of the persistence layer.
struct NoteSnapshot: Sendable {
  let id: UUID
  let content: NoteContent
  let createdAt: Date
}

/// The widget-renderable content extracted from a vault `Card`.
///
/// Text and link cards carry their display string. Suggestion cards carry the
/// selected suggestion snapshot. Photo cards carry the save-time raster
/// thumbnail, while Doodle and Bauhaus cards carry authored values decoded from
/// the vault media file.
enum NoteContent: Sendable {
  case text(String)
  case link(String)
  case file(WidgetFileContent)
  case photo(Data?)
  case video(Data?)
  case livePhoto(Data?)
  case audio
  case suggestion(SuggestionCardPayload?)
  case doodle(DoodleDrawing?)
  case bauhaus(BauhausGridDocument?)
  case unknown
}

/// Metadata needed to describe a generic file in full-size and accessory widgets.
struct WidgetFileContent: Sendable {
  let displayName: String
  let contentType: String?
  let byteSize: Int?
}

struct LatestNoteProvider: AppIntentTimelineProvider {

  /// Number of recent cards inspected to find the visible latest item.
  ///
  /// A thread save can create multiple cards at nearly the same timestamp.
  /// Looking at a small recent window lets the widget prefer the authored thread
  /// tail instead of accidentally showing its parent card.
  private static let recentCardFetchLimit = 50

  /// Requested periodic refresh cadence for relative date labels.
  ///
  /// New card content is refreshed by the app's post-save reload request; this
  /// cadence only keeps strings such as "15 min ago" from becoming too stale
  /// when the user does not open the app.
  private static let relativeDateRefreshInterval: TimeInterval = 15 * 60

  func placeholder(in context: Context) -> LatestNoteEntry {
    .sample
  }

  func snapshot(
    for configuration: LatestNoteWidgetConfiguration,
    in context: Context
  ) async -> LatestNoteEntry {
    if context.isPreview {
      return .sample
    }

    return await loadEntry(for: configuration)
  }

  func timeline(
    for configuration: LatestNoteWidgetConfiguration,
    in context: Context
  ) async -> Timeline<LatestNoteEntry> {
    let entry = await loadEntry(for: configuration)
    let next = Date.now.addingTimeInterval(Self.relativeDateRefreshInterval)
    return Timeline(entries: [entry], policy: .after(next))
  }

  private func loadEntry(for configuration: LatestNoteWidgetConfiguration) async -> LatestNoteEntry {
    do {
      guard let vault = try await JournalWidgetVaultCatalogReader.resolvedVault(
        for: configuration.vault
      ) else {
        return LatestNoteEntry(date: .now, vault: nil, note: nil)
      }

      let note = try? await loadLatestNote(in: vault.id)
      return LatestNoteEntry(date: .now, vault: vault, note: note)
    } catch {
      return LatestNoteEntry(date: .now, vault: nil, note: nil)
    }
  }

  /// Reads the latest visible note from one vault. Returns `nil` when the vault
  /// has no cards or when its store can't be opened; the view shows an empty
  /// state in both cases.
  private func loadLatestNote(in vaultID: VaultID) async throws -> NoteSnapshot? {
    let cardSnapshot: WidgetLatestCardSnapshot? = try await MainActor.run {
      let layout = try VaultStoreLayout.appGroup()
      // A widget is a short-lived, read-only process. A transient open failure
      // must never invoke the app runtime's pre-release destructive recovery.
      let store = try VaultContentStore.open(
        vaultID: vaultID,
        layout: layout,
        recoveryPolicy: .failWithoutReset
      )
      let context = store.container.mainContext

      var descriptor = FetchDescriptor<Card>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = Self.recentCardFetchLimit

      guard let card = try context.fetch(descriptor).preferredLatestWidgetCard(in: context) else {
        return nil
      }

      let latestCard = WidgetLatestCardSnapshot(
        id: card.id,
        kind: card.kind,
        body: card.body,
        createdAt: card.createdAt,
        mediaAttachment: Self.mediaAttachment(for: card, store: store)
      )

      return latestCard
    }

    guard let cardSnapshot else {
      return nil
    }

    return await cardSnapshot.noteSnapshot()
  }

  @MainActor
  private static func mediaAttachment(
    for card: Card,
    store: VaultContentStore
  ) -> WidgetMediaAttachmentSnapshot? {
    guard let attachmentKind = card.kind.widgetMediaAttachmentKind else {
      return nil
    }

    guard let attachment = card.attachments
      .sorted(using: KeyPathComparator(\.createdAt))
      .first(where: { $0.kind == attachmentKind })
    else {
      return nil
    }

    guard let resource = attachment.primaryResource else {
      return WidgetMediaAttachmentSnapshot(
        fileURL: nil,
        thumbnailData: attachment.thumbnail,
        contentType: nil,
        byteSize: nil
      )
    }

    let fileURL = store.fileURL(for: resource)
    let availableFileURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    return WidgetMediaAttachmentSnapshot(
      fileURL: availableFileURL,
      thumbnailData: attachment.thumbnail,
      contentType: resource.contentType,
      byteSize: resource.byteSize
    )
  }
}

private struct WidgetMediaAttachmentSnapshot: Sendable {
  let fileURL: URL?
  let thumbnailData: Data?
  let contentType: String?
  let byteSize: Int?
}

private struct WidgetLatestCardSnapshot: Sendable {
  let id: UUID
  let kind: Card.Kind
  let body: String
  let createdAt: Date
  let mediaAttachment: WidgetMediaAttachmentSnapshot?

  func noteSnapshot() async -> NoteSnapshot {
    NoteSnapshot(
      id: id,
      content: await content(),
      createdAt: createdAt
    )
  }

  private func content() async -> NoteContent {
    switch kind {
    case .text:
      return .text(displayText)
    case .link:
      return .link(displayText)
    case .file:
      return .file(
        WidgetFileContent(
          displayName: displayFileName,
          contentType: mediaAttachment?.contentType,
          byteSize: mediaAttachment?.byteSize
        )
      )
    case .photo:
      return .photo(mediaAttachment?.thumbnailData)
    case .video:
      return .video(mediaAttachment?.thumbnailData)
    case .livePhoto:
      return .livePhoto(mediaAttachment?.thumbnailData)
    case .audio:
      return .audio
    case .suggestion:
      guard let mediaFileURL = mediaAttachment?.fileURL else { return .suggestion(nil) }
      return .suggestion(
        await WidgetMediaFileReader.decode(SuggestionCardPayload.self, from: mediaFileURL)
      )
    case .doodle:
      guard let mediaFileURL = mediaAttachment?.fileURL else { return .doodle(nil) }
      return .doodle(
        await WidgetMediaFileReader.decode(DoodleDrawing.self, from: mediaFileURL)
      )
    case .bauhaus:
      guard let mediaFileURL = mediaAttachment?.fileURL else { return .bauhaus(nil) }
      return .bauhaus(
        await WidgetMediaFileReader.decode(BauhausGridDocument.self, from: mediaFileURL)
      )
    case .unknown:
      return .unknown
    }
  }

  private var displayText: String {
    let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? String(localized: "Untitled") : body
  }

  private var displayFileName: String {
    let name = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty == false {
      return name
    }

    if let fileURL = mediaAttachment?.fileURL,
      fileURL.lastPathComponent.isEmpty == false
    {
      return fileURL.lastPathComponent
    }

    return String(localized: "File")
  }
}

private enum WidgetMediaFileReader {

  nonisolated static func decode<Value: Decodable & Sendable>(
    _ type: Value.Type,
    from fileURL: URL
  ) async -> Value? {
    await Task.detached(priority: .utility) {
      guard let data = try? Data(contentsOf: fileURL) else {
        return nil
      }

      return try? JSONDecoder().decode(type, from: data)
    }.value
  }
}

/// Small catalog reader used by the timeline provider. App Intent entity queries
/// live in JournalIntents so controls and posting actions share the same catalog
/// representation.
private enum JournalWidgetVaultCatalogReader {

  static func resolvedVault(for entity: JournalVaultEntity?) async throws -> WidgetVaultSnapshot? {
    let descriptors = try await descriptors()
    guard descriptors.isEmpty == false else { return nil }

    if let entity,
       let descriptor = descriptors.first(where: { $0.vaultID.uuidString == entity.id }) {
      return WidgetVaultSnapshot(descriptor: descriptor)
    }

    return WidgetVaultSnapshot(descriptor: descriptors[0])
  }

  private static func descriptors() async throws -> [VaultDescriptor] {
    try await MainActor.run {
      let layout = try VaultStoreLayout.appGroup()
      let catalog = try VaultCatalogStore.open(layout: layout)
      return try catalog.vaultDescriptors()
    }
  }
}

// MARK: - View

private struct LatestNoteView: View {

  @Environment(\.widgetFamily) private var family
  let entry: LatestNoteEntry

  var body: some View {
    #if os(iOS)
    switch family {
    case .accessoryInline:
      LatestNoteInlineAccessoryView(entry: entry)
    case .accessoryCircular:
      LatestNoteCircularAccessoryView(entry: entry)
    case .accessoryRectangular:
      LatestNoteRectangularAccessoryView(entry: entry)
    default:
      standardFamilyContent
    }
    #else
    standardFamilyContent
    #endif
  }

  @ViewBuilder
  private var standardFamilyContent: some View {
    if let note = entry.note {
      LatestNoteContentCard(
        vault: entry.vault,
        note: note,
        family: family
      )
    } else {
      LatestNoteEmptyState(vault: entry.vault)
    }
  }
}

private struct LatestNoteInlineAccessoryView: View {

  let entry: LatestNoteEntry

  var body: some View {
    if let note = entry.note {
      Label(note.content.accessoryTitle, systemImage: note.content.symbolName)
    } else if let vault = entry.vault {
      WidgetVaultHeaderLabel(title: title, icon: vault.icon)
    } else {
      Label(title, systemImage: "shippingbox")
    }
  }

  private var title: String {
    if let note = entry.note {
      return note.content.accessoryTitle
    }
    return entry.vault == nil ? String(localized: "No vaults yet") : String(localized: "No notes yet")
  }
}

private struct LatestNoteCircularAccessoryView: View {

  let entry: LatestNoteEntry

  var body: some View {
    ZStack {
      AccessoryWidgetBackground()
      if let note = entry.note {
        Image(systemName: note.content.symbolName)
          .font(.title2.weight(.semibold))
      } else if let vault = entry.vault {
        WidgetVaultIconMark(icon: vault.icon, font: .title2.weight(.semibold))
      } else {
        Image(systemName: "shippingbox")
          .font(.title2.weight(.semibold))
      }
    }
    .widgetAccentable()
    .accessibilityLabel(Text(accessibilityTitle))
  }

  private var accessibilityTitle: String {
    entry.note?.content.accessoryTitle ?? (entry.vault == nil ? String(localized: "No vaults yet") : String(localized: "No notes yet"))
  }
}

private struct LatestNoteRectangularAccessoryView: View {

  let entry: LatestNoteEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      WidgetVaultHeaderLabel(
        title: headerTitle,
        icon: entry.vault?.icon ?? .default
      )
        .font(.caption2.weight(.semibold))
        .lineLimit(1)

      Text(bodyTitle)
        .font(.caption)
        .fontWeight(.medium)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetAccentable()
  }

  private var headerTitle: String {
    entry.vault?.title ?? String(localized: "Latest")
  }

  private var bodyTitle: String {
    entry.note?.content.accessoryTitle ?? (entry.vault == nil ? String(localized: "No vaults yet") : String(localized: "No notes yet"))
  }

}

private struct LatestNoteContentCard: View {

  let vault: WidgetVaultSnapshot?
  let note: NoteSnapshot
  let family: WidgetFamily

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WidgetVaultHeaderLabel(
        title: vault?.title ?? String(localized: "Latest"),
        icon: vault?.icon ?? .default
      )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      NoteContentView(
        content: note.content,
        family: family
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Text(note.createdAt, format: .relative(presentation: .named))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct NoteContentView: View {

  let content: NoteContent
  let family: WidgetFamily

  var body: some View {
    switch content {
    case .text(let text):
      Text(text)
        .font(bodyFont)
        .fontWeight(.medium)
        .lineLimit(bodyLineLimit)
        .multilineTextAlignment(.leading)
        .minimumScaleFactor(0.85)
    case .link(let urlString):
      Label {
        Text(urlString)
          .font(bodyFont)
          .fontWeight(.medium)
          .lineLimit(bodyLineLimit)
          .multilineTextAlignment(.leading)
          .minimumScaleFactor(0.85)
      } icon: {
        Image(systemName: "link")
      }
    case .file(let file):
      WidgetFileView(file: file)
    case .photo(let imageData):
      WidgetPhotoView(imageData: imageData)
    case .video(let imageData):
      WidgetPhotoView(
        imageData: imageData,
        fallbackTitle: "Video",
        fallbackSystemImage: "video",
        accessibilityLabel: "Video"
      )
    case .livePhoto(let imageData):
      WidgetPhotoView(
        imageData: imageData,
        fallbackTitle: "Live Photo",
        fallbackSystemImage: "livephoto",
        accessibilityLabel: "Live Photo"
      )
    case .audio:
      WidgetMediaLabel(title: "Audio", systemImage: "waveform")
    case .suggestion(let suggestion):
      WidgetSuggestionView(suggestion: suggestion)
    case .doodle(let drawing):
      WidgetDoodleView(drawing: drawing)
    case .bauhaus(let document):
      WidgetBauhausView(document: document)
    case .unknown:
      WidgetMediaLabel(title: "Untitled", systemImage: "questionmark.square.dashed")
    }
  }

  private var bodyFont: Font {
    switch family {
    case .systemSmall: .subheadline
    case .systemLarge: .title3
    default: .body
    }
  }

  private var bodyLineLimit: Int {
    switch family {
    case .systemSmall: 4
    case .systemLarge: 14
    default: 4
    }
  }
}

private struct WidgetPhotoView: View {

  let imageData: Data?
  var fallbackTitle: LocalizedStringResource = "Photo"
  var fallbackSystemImage: String = "photo"
  var accessibilityLabel: LocalizedStringResource = "Photo"

  var body: some View {
    #if canImport(UIKit)
    if let uiImage = imageData.flatMap(UIImage.init(data:)) {
      WidgetRenderedMediaFrame {
        Image(uiImage: uiImage)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      }
      .accessibilityLabel(Text(accessibilityLabel))
    } else {
      WidgetMediaLabel(title: fallbackTitle, systemImage: fallbackSystemImage)
    }
    #elseif canImport(AppKit)
    if let nsImage = imageData.flatMap(NSImage.init(data:)) {
      WidgetRenderedMediaFrame {
        Image(nsImage: nsImage)
          .resizable()
          .scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      }
      .accessibilityLabel(Text(accessibilityLabel))
    } else {
      WidgetMediaLabel(title: fallbackTitle, systemImage: fallbackSystemImage)
    }
    #endif
  }
}

private struct WidgetDoodleView: View {

  let drawing: DoodleDrawing?

  var body: some View {
    if let drawing {
      WidgetRenderedMediaFrame {
        DoodleDrawingView(
          drawing: drawing,
          inkColor: .primary,
          displayAspectRatio: WidgetVisualMediaMetrics.aspectRatio
        )
        .padding(8)
      }
      .accessibilityLabel(Text("Doodle"))
    } else {
      WidgetMediaLabel(title: "Doodle", systemImage: "scribble.variable")
    }
  }
}

private struct WidgetBauhausView: View {

  let document: BauhausGridDocument?

  var body: some View {
    if let document {
      WidgetRenderedMediaFrame {
        BauhausGridArtworkView(artwork: document.artwork)
          .padding(6)
      }
      .accessibilityLabel(Text("Bauhaus"))
    } else {
      WidgetMediaLabel(title: "Bauhaus", systemImage: "square.grid.3x3.square")
    }
  }
}

private struct WidgetRenderedMediaFrame<Content: View>: View {

  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.secondary.opacity(0.08))

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    .aspectRatio(WidgetVisualMediaMetrics.aspectRatio, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private enum WidgetVisualMediaMetrics {
  static let aspectRatio: CGFloat = 1
}

private struct WidgetSuggestionView: View {

  let suggestion: SuggestionCardPayload?

  var body: some View {
    if let suggestion {
      Label {
        Text(displayTitle(for: suggestion))
          .lineLimit(3)
          .minimumScaleFactor(0.8)
      } icon: {
        Image(systemName: "sparkles")
      }
      .font(.body.weight(.medium))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    } else {
      WidgetMediaLabel(title: "Suggestion", systemImage: "sparkles")
    }
  }

  private func displayTitle(for suggestion: SuggestionCardPayload) -> String {
    let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? String(localized: "Suggestion") : title
  }
}

private struct WidgetMediaLabel: View {

  let title: LocalizedStringResource
  let systemImage: String

  var body: some View {
    Label {
      Text(title)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.body.weight(.medium))
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

/// Filename-first rendering for arbitrary file cards.
private struct WidgetFileView: View {

  let file: WidgetFileContent

  var body: some View {
    VStack(spacing: 5) {
      Label {
        Text(file.displayName)
          .lineLimit(3)
          .minimumScaleFactor(0.75)
      } icon: {
        Image(systemName: "doc")
      }
      .font(.body.weight(.medium))

      if metadata.isEmpty == false {
        Text(metadata.joined(separator: " · "))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
    }
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var metadata: [String] {
    var values: [String] = []

    if let contentType = file.contentType,
      contentType.isEmpty == false
    {
      values.append(UTType(contentType)?.localizedDescription ?? contentType)
    }

    if let byteSize = file.byteSize {
      values.append(
        ByteCountFormatter.string(
          fromByteCount: Int64(byteSize),
          countStyle: .file
        )
      )
    }

    return values
  }
}

private struct LatestNoteEmptyState: View {

  let vault: WidgetVaultSnapshot?

  var body: some View {
    VStack(spacing: 6) {
      Group {
        if let vault {
          WidgetVaultIconMark(icon: vault.icon, font: .title2)
        } else {
          Image(systemName: "shippingbox")
            .font(.title2)
        }
      }
        .foregroundStyle(.secondary)

      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var title: String {
    vault == nil ? String(localized: "No vaults yet") : String(localized: "No cards yet")
  }

}

private struct WidgetVaultHeaderLabel: View {

  let title: String
  let icon: VaultIcon

  var body: some View {
    Label {
      Text(title)
    } icon: {
      WidgetVaultIconMark(icon: icon, font: .body)
    }
  }
}

private struct WidgetVaultIconMark: View {

  let icon: VaultIcon
  let font: Font

  var body: some View {
    switch icon.kind {
    case .systemImage:
      Image(systemName: icon.value)
        .font(font)
    case .emoji:
      Text(icon.value)
        .font(font)
    }
  }
}

// MARK: - Formatting Helpers

extension Array where Element == Card {

  /// Picks the card the Latest Note widget should render from a date-sorted
  /// recent window.
  ///
  /// For a multi-card thread, this prefers the first visible leaf card, so a
  /// single thread save displays the authored last item instead of its parent.
  /// The fallback preserves normal "newest by date" behavior for malformed or
  /// partially imported edge data.
  @MainActor
  fileprivate func preferredLatestWidgetCard(in context: ModelContext) throws -> Card? {
    let edges = try context.fetch(FetchDescriptor<CardEdge>())
    let edgeByCardID = edges.reduce(into: [UUID: CardEdge]()) { result, edge in
      result[edge.cardID] = edge
    }
    let parentEdgeIDs = Set(edges.compactMap(\.parentEdgeID))

    return first { card in
      guard let edge = edgeByCardID[card.id] else { return false }
      return parentEdgeIDs.contains(edge.id) == false
    } ?? first { edgeByCardID[$0.id] != nil } ?? first
  }
}

extension Card.Kind {

  /// Media attachment kind the widget needs to decode this card visually.
  ///
  /// Text, link, audio, and unknown cards do not need a visual media file for
  /// the current widget treatment. File cards resolve their primary resource
  /// so the widget can show its persisted content type and byte count.
  fileprivate var widgetMediaAttachmentKind: Attachment.Kind? {
    switch self {
    case .file:
      return .file
    case .photo:
      return .photo
    case .video:
      return .video
    case .livePhoto:
      return .livePhoto
    case .doodle:
      return .doodle
    case .bauhaus:
      return .bauhaus
    case .suggestion:
      return .suggestion
    case .text, .link, .audio, .unknown:
      return nil
    }
  }
}

extension NoteContent {

  /// SF Symbol used by the latest-note label for this content type.
  fileprivate var symbolName: String {
    switch self {
    case .text:
      return "note.text"
    case .link:
      return "link"
    case .file:
      return "doc"
    case .photo:
      return "photo"
    case .video:
      return "video"
    case .livePhoto:
      return "livephoto"
    case .audio:
      return "waveform"
    case .suggestion:
      return "sparkles"
    case .doodle:
      return "scribble.variable"
    case .bauhaus:
      return "square.grid.3x3.square"
    case .unknown:
      return "questionmark.square.dashed"
    }
  }

  /// Short text for constrained accessory families.
  fileprivate var accessoryTitle: String {
    switch self {
    case .text(let text):
      let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedText.isEmpty ? String(localized: "Untitled") : trimmedText
    case .link(let urlString):
      let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedURLString.isEmpty ? String(localized: "Link") : trimmedURLString
    case .file(let file):
      return file.displayName
    case .photo:
      return String(localized: "Photo")
    case .video:
      return String(localized: "Video")
    case .livePhoto:
      return String(localized: "Live Photo")
    case .audio:
      return String(localized: "Audio")
    case .suggestion(let suggestion):
      let title = suggestion?.title.trimmingCharacters(in: .whitespacesAndNewlines)
      if let title, title.isEmpty == false {
        return title
      }
      return String(localized: "Suggestion")
    case .doodle:
      return String(localized: "Doodle")
    case .bauhaus:
      return String(localized: "Bauhaus")
    case .unknown:
      return String(localized: "Untitled")
    }
  }
}

// MARK: - Sample Data

extension LatestNoteEntry {
  /// Placeholder entry for the widget gallery and redacted previews.
  static let sample = LatestNoteEntry(
    date: .now,
    vault: .sample,
    note: .sample
  )
}

extension WidgetVaultSnapshot {
  /// Placeholder vault for the widget gallery and redacted previews.
  static let sample = WidgetVaultSnapshot(
    id: VaultID(rawValue: UUID()),
    title: "Personal",
    icon: .emoji("📓")
  )
}

extension NoteSnapshot {
  /// Placeholder content for the widget gallery and redacted previews.
  static let sample = NoteSnapshot(
    id: UUID(),
    content: .text(
      "Had a slow morning and a long walk by the river. Felt good to step away from the screen for a while."
    ),
    createdAt: .now.addingTimeInterval(-1_800)
  )

  /// Placeholder content for the doodle widget render path.
  static let sampleDoodle = NoteSnapshot(
    id: UUID(),
    content: .doodle(.widgetSample),
    createdAt: .now.addingTimeInterval(-600)
  )

  /// Placeholder content for the Bauhaus widget render path.
  static let sampleBauhaus = NoteSnapshot(
    id: UUID(),
    content: .bauhaus(.widgetSample),
    createdAt: .now.addingTimeInterval(-900)
  )
}

private extension DoodleDrawing {
  static let widgetSample = DoodleDrawing(
    strokes: [
      DoodleStroke(
        points: [
          DoodlePoint(x: 36, y: 178, time: 0.0, width: 5),
          DoodlePoint(x: 76, y: 118, time: 0.2, width: 7),
          DoodlePoint(x: 126, y: 156, time: 0.4, width: 6),
          DoodlePoint(x: 174, y: 82, time: 0.6, width: 8),
          DoodlePoint(x: 216, y: 142, time: 0.8, width: 5),
        ],
        width: 6
      ),
      DoodleStroke(
        points: [
          DoodlePoint(x: 56, y: 224, time: 1.0, width: 4),
          DoodlePoint(x: 112, y: 214, time: 1.2, width: 6),
          DoodlePoint(x: 178, y: 232, time: 1.4, width: 4),
        ],
        width: 5
      ),
    ],
    canvasSize: CGSize(width: 240, height: 300),
    duration: 1.4
  )
}

private extension BauhausGridDocument {
  static let widgetSample = BauhausGridDocument(artwork: .widgetSample)
}

private extension BauhausGridArtwork {
  static let widgetSample: BauhausGridArtwork = {
    var artwork = BauhausGridArtwork()
    artwork[BauhausGridPosition(row: 0, column: 1)] = BauhausTile(shape: .circle, shapeSwatch: .slot1)
    artwork[BauhausGridPosition(row: 1, column: 2)] = BauhausTile(shape: .semicircleTrailing, shapeSwatch: .slot5)
    artwork[BauhausGridPosition(row: 2, column: 0)] = BauhausTile(shape: .triangleBottomTrailing, shapeSwatch: .slot4)
    artwork[BauhausGridPosition(row: 2, column: 3)] = BauhausTile(shape: .square, shapeSwatch: .slot2)
    artwork[BauhausGridPosition(row: 3, column: 1)] = BauhausTile(shape: .quarterCircleTopTrailing, shapeSwatch: .slot6)
    artwork[BauhausGridPosition(row: 4, column: 4)] = BauhausTile(shape: .paddedCircle, shapeSwatch: .slot7)
    return artwork
  }()
}

// MARK: - Preview

#Preview(as: .systemSmall) {
  LatestNoteWidget()
} timeline: {
  LatestNoteEntry(date: .now, vault: .sample, note: .sample)
  LatestNoteEntry(date: .now, vault: .sample, note: .sampleDoodle)
  LatestNoteEntry(date: .now, vault: .sample, note: .sampleBauhaus)
  LatestNoteEntry(date: .now, vault: .sample, note: nil)
  LatestNoteEntry(date: .now, vault: nil, note: nil)
}
