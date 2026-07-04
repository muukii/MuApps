import AppIntents
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
    return trimmedTitle.isEmpty ? "Untitled Vault" : trimmedTitle
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
    return trimmedTitle.isEmpty ? "Untitled Vault" : trimmedTitle
  }
}

/// A `Sendable`, value-type view of the latest vault `Card`. The widget renders
/// this rather than holding a SwiftData model reference, keeping the timeline
/// entry `Sendable` and the views free of the persistence layer.
struct NoteSnapshot: Sendable, Hashable {
  let id: UUID
  let content: NoteContent
  let createdAt: Date
}

/// The widget-renderable content extracted from a vault `Card`.
///
/// Text and link cards carry their display string. Doodle and Bauhaus cards
/// carry only mirrored thumbnail bytes, not the full authored document JSON, so
/// the extension can render them without linking capture frameworks or touching
/// media files.
enum NoteContent: Sendable, Hashable {
  case text(String)
  case link(String)
  case doodle(thumbnailData: Data?)
  case bauhaus(thumbnailData: Data?)
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
    try await MainActor.run {
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

      let attachments = try Self.attachments(for: card.id, in: context)
      return NoteSnapshot(
        id: card.id,
        content: card.widgetContent(attachments: attachments),
        createdAt: card.createdAt
      )
    }
  }

  @MainActor
  private static func attachments(for cardID: UUID, in context: ModelContext) throws -> [Attachment] {
    var descriptor = FetchDescriptor<Attachment>(
      predicate: #Predicate { $0.cardID == cardID },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    descriptor.fetchLimit = 8
    return try context.fetch(descriptor)
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
    return entry.vault == nil ? "No vaults yet" : "No notes yet"
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
    entry.note?.content.accessoryTitle ?? (entry.vault == nil ? "No vaults yet" : "No notes yet")
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
    entry.vault?.title ?? "Latest"
  }

  private var bodyTitle: String {
    entry.note?.content.accessoryTitle ?? (entry.vault == nil ? "No vaults yet" : "No notes yet")
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
      Label(vault?.title ?? "Latest", systemImage: note.content.symbolName)
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
    case .doodle(let thumbnailData):
      DoodleThumbnailView(thumbnailData: thumbnailData)
    case .bauhaus(let thumbnailData):
      DoodleThumbnailView(
        thumbnailData: thumbnailData,
        fallbackTitle: "Bauhaus",
        fallbackSymbolName: "square.grid.3x3.square"
      )
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

private struct DoodleThumbnailView: View {

  let thumbnailData: Data?
  let fallbackTitle: LocalizedStringResource
  let fallbackSymbolName: String

  init(
    thumbnailData: Data?,
    fallbackTitle: LocalizedStringResource = "Doodle",
    fallbackSymbolName: String = "scribble.variable"
  ) {
    self.thumbnailData = thumbnailData
    self.fallbackTitle = fallbackTitle
    self.fallbackSymbolName = fallbackSymbolName
  }

  var body: some View {
    if let image = thumbnailData.flatMap(UIImage.init(data:)) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
          .secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityLabel(Text(fallbackTitle))
    } else {
      Label {
        Text(fallbackTitle)
      } icon: {
        Image(systemName: fallbackSymbolName)
      }
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
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
    vault == nil ? "No vaults yet" : "No cards yet"
  }

  private var symbolName: String {
    vault == nil ? "shippingbox" : "note.text"
  }
}

// MARK: - Formatting Helpers

extension Card {

  /// The widget content for this card. Text cards render their written body;
  /// doodle and Bauhaus cards render mirrored thumbnails, and other media cards
  /// keep their modality label until they get a dedicated widget treatment.
  fileprivate func widgetContent(attachments: [Attachment]) -> NoteContent {
    switch kind {
    case .text:
      return .text(displayText)
    case .link:
      return .link(displayText)
    case .photo:
      return .text("Photo")
    case .audio:
      return .text("Audio")
    case .doodle:
      return .doodle(
        thumbnailData: attachments.first(matching: .doodle)?.thumbnail
      )
    case .bauhaus:
      return .bauhaus(
        thumbnailData: attachments.first(matching: .bauhaus)?.thumbnail
      )
    case .unknown:
      return .text("Untitled")
    }
  }

  /// The fallback label for non-visual widget content.
  fileprivate var displayText: String {
    let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? "Untitled" : body
  }
}

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

extension NoteContent {

  /// SF Symbol used by the latest-note label for this content type.
  fileprivate var symbolName: String {
    switch self {
    case .text:
      return "note.text"
    case .link:
      return "link"
    case .doodle:
      return "scribble.variable"
    case .bauhaus:
      return "square.grid.3x3.square"
    }
  }

  /// Short text for constrained accessory families.
  fileprivate var accessoryTitle: String {
    switch self {
    case .text(let text):
      let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedText.isEmpty ? "Untitled" : trimmedText
    case .link(let urlString):
      let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedURLString.isEmpty ? "Link" : trimmedURLString
    case .doodle:
      return "Doodle"
    case .bauhaus:
      return "Bauhaus"
    }
  }
}

extension Array where Element == Attachment {

  fileprivate func first(matching kind: Attachment.Kind) -> Attachment? {
    first { $0.kind == kind }
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

  /// Placeholder content for the doodle rendering path when a real thumbnail
  /// has not been loaded from the selected vault store.
  static let sampleDoodle = NoteSnapshot(
    id: UUID(),
    content: .doodle(thumbnailData: nil),
    createdAt: .now.addingTimeInterval(-600)
  )

  /// Placeholder content for the Bauhaus rendering path when a real thumbnail
  /// has not been loaded from the selected vault store.
  static let sampleBauhaus = NoteSnapshot(
    id: UUID(),
    content: .bauhaus(thumbnailData: nil),
    createdAt: .now.addingTimeInterval(-900)
  )
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
