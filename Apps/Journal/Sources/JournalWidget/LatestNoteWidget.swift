import AppIntents
import CaptureBauhaus
import CaptureDoodle
import JournalVault
import SwiftData
import SwiftUI
import UIKit
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
  private let supportedFamilies: [WidgetFamily] = [
    .systemSmall,
    .systemMedium,
    .systemLarge,
    .accessoryInline,
    .accessoryCircular,
    .accessoryRectangular,
  ]

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

/// App Intents representation of a Journal vault for WidgetKit pickers.
///
/// This intentionally exposes only the durable vault id and title. Permissions,
/// sync state, and content stay behind `JournalVault` stores because the picker
/// only needs enough data to identify the timeline source.
struct JournalVaultEntity: AppEntity, Identifiable, Hashable {

  let id: String
  let title: String

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Vault"
  static let defaultQuery = JournalVaultEntityQuery()

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(displayTitle)")
  }

  init(descriptor: VaultDescriptor) {
    self.id = descriptor.vaultID.uuidString
    self.title = descriptor.title
  }

  init(id: String, title: String) {
    self.id = id
    self.title = title
  }

  private var displayTitle: String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? String(localized: "Untitled Vault") : trimmedTitle
  }
}

/// Query object that lets WidgetKit list and resolve vault choices.
///
/// Widget configuration runs in the extension process, so every query opens the
/// lightweight catalog store from the App Group instead of asking the app's
/// `JournalVaultRuntime`.
struct JournalVaultEntityQuery: EntityQuery, EntityStringQuery {

  func entities(for identifiers: [JournalVaultEntity.ID]) async throws -> [JournalVaultEntity] {
    let identifierSet = Set(identifiers)
    return try await JournalWidgetVaultCatalogReader.entities()
      .filter { identifierSet.contains($0.id) }
  }

  func suggestedEntities() async throws -> [JournalVaultEntity] {
    try await JournalWidgetVaultCatalogReader.entities()
  }

  func defaultResult() async -> JournalVaultEntity? {
    try? await JournalWidgetVaultCatalogReader.entities().first
  }

  func entities(matching string: String) async throws -> [JournalVaultEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.isEmpty == false else {
      return try await suggestedEntities()
    }

    return try await JournalWidgetVaultCatalogReader.entities()
      .filter { $0.title.localizedCaseInsensitiveContains(query) }
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

  init(descriptor: VaultDescriptor) {
    self.id = descriptor.vaultID
    self.title = Self.displayTitle(for: descriptor.title)
  }

  init(id: VaultID, title: String) {
    self.id = id
    self.title = Self.displayTitle(for: title)
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
/// Text and link cards carry their display string. Photo cards carry the
/// save-time raster thumbnail, while Doodle and Bauhaus cards carry authored
/// values decoded from the vault media file.
enum NoteContent: Sendable {
  case text(String)
  case link(String)
  case photo(Data?)
  case video(Data?)
  case livePhoto(Data?)
  case audio
  case doodle(DoodleDrawing?)
  case bauhaus(BauhausGridDocument?)
  case unknown
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
      let store = try VaultContentStore.open(vaultID: vaultID, layout: layout)
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
        mediaAttachment: try Self.mediaAttachment(for: card, in: context, store: store)
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
    in context: ModelContext,
    store: VaultContentStore
  ) throws -> WidgetMediaAttachmentSnapshot? {
    guard let attachmentKind = card.kind.widgetMediaAttachmentKind else {
      return nil
    }

    let cardID = card.id
    var descriptor = FetchDescriptor<Attachment>(
      predicate: #Predicate { $0.cardID == cardID },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    descriptor.fetchLimit = 8

    guard let attachment = try context.fetch(descriptor).first(where: { $0.kind == attachmentKind }) else {
      return nil
    }

    let primaryResourceID = attachment.primaryResourceID
    var resourceDescriptor = FetchDescriptor<AttachmentResource>(
      predicate: #Predicate { $0.id == primaryResourceID }
    )
    resourceDescriptor.fetchLimit = 1
    guard let resource = try context.fetch(resourceDescriptor).first else {
      return WidgetMediaAttachmentSnapshot(
        fileURL: nil,
        thumbnailData: attachment.thumbnail
      )
    }

    let fileURL = store.fileURL(for: resource)
    let availableFileURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    return WidgetMediaAttachmentSnapshot(
      fileURL: availableFileURL,
      thumbnailData: attachment.thumbnail
    )
  }
}

private struct WidgetMediaAttachmentSnapshot: Sendable {
  let fileURL: URL?
  let thumbnailData: Data?
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
    case .photo:
      return .photo(mediaAttachment?.thumbnailData)
    case .video:
      return .video(mediaAttachment?.thumbnailData)
    case .livePhoto:
      return .livePhoto(mediaAttachment?.thumbnailData)
    case .audio:
      return .audio
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

/// Small catalog reader shared by the App Intent query and the timeline provider.
private enum JournalWidgetVaultCatalogReader {

  static func entities() async throws -> [JournalVaultEntity] {
    (try await descriptors()).map(JournalVaultEntity.init)
  }

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
    switch family {
    case .accessoryInline:
      LatestNoteInlineAccessoryView(entry: entry)
    case .accessoryCircular:
      LatestNoteCircularAccessoryView(entry: entry)
    case .accessoryRectangular:
      LatestNoteRectangularAccessoryView(entry: entry)
    default:
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
}

private struct LatestNoteInlineAccessoryView: View {

  let entry: LatestNoteEntry

  var body: some View {
    Label(title, systemImage: entry.note?.content.symbolName ?? "note.text")
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
      Image(systemName: entry.note?.content.symbolName ?? emptySymbolName)
        .font(.title2.weight(.semibold))
    }
    .widgetAccentable()
    .accessibilityLabel(Text(accessibilityTitle))
  }

  private var emptySymbolName: String {
    entry.vault == nil ? "shippingbox" : "note.text"
  }

  private var accessibilityTitle: String {
    entry.note?.content.accessoryTitle ?? (entry.vault == nil ? String(localized: "No vaults yet") : String(localized: "No notes yet"))
  }
}

private struct LatestNoteRectangularAccessoryView: View {

  let entry: LatestNoteEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(headerTitle, systemImage: entry.note?.content.symbolName ?? emptySymbolName)
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

  private var emptySymbolName: String {
    entry.vault == nil ? "shippingbox" : "note.text"
  }
}

private struct LatestNoteContentCard: View {

  let vault: WidgetVaultSnapshot?
  let note: NoteSnapshot
  let family: WidgetFamily

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(vault?.title ?? String(localized: "Latest"), systemImage: note.content.symbolName)
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

private struct LatestNoteEmptyState: View {

  let vault: WidgetVaultSnapshot?

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbolName)
        .font(.title2)
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

  private var symbolName: String {
    vault == nil ? "shippingbox" : "note.text"
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
  /// the current widget treatment.
  fileprivate var widgetMediaAttachmentKind: Attachment.Kind? {
    switch self {
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
    case .photo:
      return "photo"
    case .video:
      return "video"
    case .livePhoto:
      return "livephoto"
    case .audio:
      return "waveform"
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
    case .photo:
      return String(localized: "Photo")
    case .video:
      return String(localized: "Video")
    case .livePhoto:
      return String(localized: "Live Photo")
    case .audio:
      return String(localized: "Audio")
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
    title: "Personal"
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
