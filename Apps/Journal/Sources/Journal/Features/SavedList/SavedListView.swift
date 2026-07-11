import AppUIComponents
import AVFoundation
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import JournalVault
import MuColor
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WidgetKit
import Algorithms

/// Vault-backed entries list.
///
/// This screen intentionally reads only the selected `VaultInstance`. It does
/// not receive any legacy persistence container; legacy data enters the current
/// UI only after the sync layer has imported it into a vault store.
struct SavedListView: View {

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  var body: some View {
    Group {
      if let vault = vaultRuntime.selectedVault,
        vaultRuntime.selectedVaultState == .active
      {
        VaultSavedListContentView(vault: vault)
          .modelContainer(vault.contentStore.container)
      } else {
        ContentUnavailableView("Vault Not Ready", systemImage: "externaldrive")
      }
    }
    .navigationTitle(vaultRuntime.selectedVault?.title ?? String(localized: "Entries"))
    .journalInlineNavigationTitle()
  }
}

/// Live SwiftData-backed content for the selected vault.
///
/// `SavedListView` installs the selected vault's `ModelContainer`; this view
/// observes `CardEdge` rows and traverses relationships to cards, attachments,
/// and resources. CloudKit imports update SwiftData models, and this view
/// responds through normal SwiftData observation rather than a manual reload.
private struct VaultSavedListContentView: View {

  let vault: VaultInstance

  @Environment(\.calendar) private var calendar
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.appPalette) private var palette
  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @Query(
    sort: [
      SortDescriptor(\JournalVault.CardEdge.createdAt, order: .reverse),
      SortDescriptor(\JournalVault.CardEdge.sortIndex),
    ]
  )
  private var edges: [JournalVault.CardEdge]

  @State private var sharePreviewPresentation: CardSharePreviewPresentation?
  @State private var editPresentation: VaultSavedEntryEditPresentation?
  @State private var isEditDraftLoading = false
  @State private var isSavingEdit = false
  @State private var isDeletingEntry = false
  @State private var editErrorMessage: String?
  @State private var deleteErrorMessage: String?
  @State private var areStacksExpanded = false
  @Namespace private var stackExpansionNamespace
  @Namespace private var navigationTransitionNamespace

  var body: some View {
    let columns = SavedListGrid.columns(for: horizontalSizeClass)
    let isMutationDisabled = isEditDraftLoading || isSavingEdit || isDeletingEntry
    let visibleSections = visibleDaySections

    ScrollView {
      LazyVStack(alignment: .leading, spacing: daySectionSpacing) {
        ForEach(visibleSections) { section in
          VaultSavedDaySectionView(
            section: section,
            columns: columns,
            childEntriesByParentID: childEntriesByParentID,
            areStacksExpanded: areStacksExpanded,
            isEditingDisabled: isMutationDisabled,
            isDeletingDisabled: isMutationDisabled,
            stackExpansionNamespace: stackExpansionNamespace,
            transitionNamespace: navigationTransitionNamespace,
            onShare: presentSharePreview,
            onEdit: presentEditDraft,
            onDelete: deleteEntry
          )
        }
      }
      .padding(cardSpacing)
    }
    .overlay {
      if sections.isEmpty {
        ContentUnavailableView("No Cards", systemImage: "book.closed")
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .toolbar {
      if hasStackedEntries {
        ToolbarItem(placement: .journalTrailingAction) {
          Button {
            withAnimation(.smooth) {
              areStacksExpanded.toggle()
            }
          } label: {
            Image(systemName: areStacksExpanded ? "square.stack.3d.up" : "square.grid.2x2")
          }
          .accessibilityLabel(areStacksExpanded ? "Collapse Stacks" : "Expand Stacks")
        }
      }
    }
    .refreshable {
      await vaultRuntime.refresh()
    }
    .sheet(item: $sharePreviewPresentation) { presentation in
      CardSharePreviewScreen(
        snapshot: presentation.snapshot,
        palette: presentation.palette
      )
    }
    .sheet(item: $editPresentation) { presentation in
      VaultSavedEntryEditSheet(
        draft: presentation.draft,
        isSaving: isSavingEdit,
        onSave: {
          saveEdit(presentation)
        },
        onCancel: {
          editPresentation = nil
        }
      )
      .presentationBackground(.background)
    }
    .alert("Could Not Edit Card", isPresented: editErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let editErrorMessage {
        Text(editErrorMessage)
      }
    }
    .alert("Could Not Delete Card", isPresented: deleteErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let deleteErrorMessage {
        Text(deleteErrorMessage)
      }
    }
  }

  private var sections: [VaultSavedDaySection] {
    VaultSavedDaySection.sections(for: rootEntries, calendar: calendar)
  }

  private var childEntriesByParentID: [UUID: [VaultSavedEntry]] {
    entries
      .filter { entry in
        entry.parentEdgeID.map(edgeIDs.contains) ?? false
      }
      .reduce(into: [UUID: [VaultSavedEntry]]()) { result, entry in
        guard let parentEdgeID = entry.parentEdgeID else { return }
        result[parentEdgeID, default: []].append(entry)
      }
      .mapValues { $0.sortedForVaultListSiblings() }
  }

  private var entries: [VaultSavedEntry] {
    edges.compactMap { edge in
      guard let card = edge.card else { return nil }
      return VaultSavedEntry(edge: edge, card: card, store: vault.contentStore)
    }
  }

  private var edgeIDs: Set<UUID> {
    Set(edges.map(\.id))
  }

  private var rootEntries: [VaultSavedEntry] {
    entries
      .filter { entry in
        entry.parentEdgeID.map(edgeIDs.contains) != true
      }
      .sortedForVaultList()
  }

  private var hasStackedEntries: Bool {
    childEntriesByParentID.values.contains { $0.isEmpty == false }
  }

  private var visibleDaySections: [VaultSavedDaySection] {
    guard areStacksExpanded else {
      return sections
    }

    return VaultSavedDaySection.sections(
      for: expandedEntries(),
      calendar: calendar
    )
  }

  private func expandedEntries() -> [VaultSavedEntry] {
    var result: [VaultSavedEntry] = []

    func appendSubtree(startingAt entry: VaultSavedEntry) {
      result.append(entry)
      for child in childEntriesByParentID[entry.edgeID] ?? [] {
        appendSubtree(startingAt: child)
      }
    }

    for root in sections.flatMap(\.entries) {
      appendSubtree(startingAt: root)
    }

    return result
  }

  private var editErrorPresentation: Binding<Bool> {
    Binding {
      editErrorMessage != nil
    } set: { isPresented in
      if isPresented == false {
        editErrorMessage = nil
      }
    }
  }

  private var deleteErrorPresentation: Binding<Bool> {
    Binding {
      deleteErrorMessage != nil
    } set: { isPresented in
      if isPresented == false {
        deleteErrorMessage = nil
      }
    }
  }

  private func presentEditDraft(for entry: VaultSavedEntry) {
    guard isEditDraftLoading == false, isSavingEdit == false, isDeletingEntry == false else {
      return
    }

    isEditDraftLoading = true

    Task { @MainActor in
      defer { isEditDraftLoading = false }

      do {
        editPresentation = VaultSavedEntryEditPresentation(
          cardID: entry.cardID,
          draft: try await entry.editDraft()
        )
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }

  private func presentSharePreview(for entry: VaultSavedEntry) {
    sharePreviewPresentation = CardSharePreviewPresentation(
      snapshot: CardShareSnapshot(source: entry.shareSource),
      palette: palette
    )
  }

  private func saveEdit(_ presentation: VaultSavedEntryEditPresentation) {
    guard isSavingEdit == false else {
      return
    }

    isSavingEdit = true

    Task { @MainActor in
      defer { isSavingEdit = false }

      do {
        guard let vault = vaultRuntime.selectedVault else {
          throw VaultSavedEntryEditDraftError.vaultUnavailable
        }

        let draft = try presentation.draft.savingSnapshot().vaultDraft()
        try vault.contentStore.updateCard(cardID: presentation.cardID, with: draft)
        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
        editPresentation = nil
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }

  @MainActor
  private func deleteEntry(_ entry: VaultSavedEntry) async -> Bool {
    guard isDeletingEntry == false, isEditDraftLoading == false, isSavingEdit == false else {
      return false
    }

    isDeletingEntry = true
    defer { isDeletingEntry = false }

    do {
      guard let vault = vaultRuntime.selectedVault else {
        throw VaultSavedEntryEditDraftError.vaultUnavailable
      }

      try vault.contentStore.deleteCardEdge(edgeID: entry.edgeID)
      if editPresentation?.cardID == entry.cardID {
        editPresentation = nil
      }
      await vaultRuntime.refresh()
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      return true
    } catch {
      deleteErrorMessage = error.localizedDescription
      return false
    }
  }
}

/// One modal editing session for a saved vault card.
///
/// The sheet edits a detached `CardEditDraft`; only the save action writes the
/// edited payload back to the selected vault store.
private struct VaultSavedEntryEditPresentation: Identifiable {
  let id = UUID()
  let cardID: UUID
  let draft: CardEditDraft
}

/// One presentation of the generated share-preview sheet.
private struct CardSharePreviewPresentation: Identifiable {
  let id = UUID()
  let snapshot: CardShareSnapshot
  let palette: Palette
}

// MARK: - Live Entry Projection

/// Live saved-entry handle used by the list and detail UI.
///
/// The handle carries SwiftData model references. Display, share, and edit
/// values are derived at the edge of each operation, so CloudKit imports update
/// the UI through SwiftData observation instead of a hand-built reload snapshot.
private struct VaultSavedEntry: Identifiable {

  let edge: JournalVault.CardEdge
  let card: JournalVault.Card
  let store: VaultContentStore

  var id: UUID { edgeID }

  var edgeID: UUID { edge.id }
  var cardID: UUID { card.id }
  var parentEdgeID: UUID? { edge.parentEdgeID }
  var sortIndex: Int { edge.sortIndex }
  var kind: JournalVault.Card.Kind { card.kind }
  var body: String { card.body }
  var createdAt: Date { card.createdAt }
  var updatedAt: Date { card.updatedAt }
  var location: JournalVault.Coordinate? { card.location }

  var attachment: VaultSavedAttachment? {
    card.attachments
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .lazy
      .compactMap { VaultSavedAttachment(attachment: $0, store: store) }
      .first
  }
}

extension VaultSavedEntry {

  /// Rehydrates this saved card into the shared editing draft model.
  ///
  /// Media cards require the full vault media file. Raster previews are
  /// intentionally not used to create a lossy edit draft.
  @MainActor
  fileprivate func editDraft() async throws -> CardEditDraft {
    switch kind {
    case .text:
      return CardEditDraft(kind: .text, text: body, location: location)
    case .link:
      return CardEditDraft(kind: .link, text: body, location: location)
    case .photo:
      let data = try await mediaData(matching: .photo)
      guard let image = UIImage(data: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .photo,
        photo: CapturedPhoto(imageData: data, pixelSize: image.pixelSize),
        location: location
      )
    case .video:
      let fileURL = try mediaFileURL(matching: .video)
      let editableURL = try VaultSavedEntryEditMediaPreparer.mediaCopy(
        from: fileURL,
        fallbackPathExtension: "mov"
      )
      let resource = attachment?.primaryResource
      return CardEditDraft(
        kind: .video,
        video: CapturedVideo(
          fileURL: editableURL,
          thumbnailData: attachment?.thumbnail,
          pixelSize: resource?.pixelSize ?? .zero,
          duration: resource?.duration ?? 0,
          contentTypeIdentifier: resource?.contentType,
          byteSize: resource?.byteSize
        ),
        location: location
      )
    case .livePhoto:
      let stillData = try await mediaData(matching: .stillImage)
      let pairedVideoFileURL = try mediaFileURL(matching: .pairedVideo)
      let editablePairedVideoURL = try VaultSavedEntryEditMediaPreparer.mediaCopy(
        from: pairedVideoFileURL,
        fallbackPathExtension: "mov"
      )
      let stillResource = try mediaResource(matching: .stillImage)
      let pairedVideoResource = try mediaResource(matching: .pairedVideo)
      return CardEditDraft(
        kind: .livePhoto,
        livePhoto: CapturedLivePhoto(
          stillImageData: stillData,
          pairedVideoFileURL: editablePairedVideoURL,
          thumbnailData: attachment?.thumbnail,
          pixelSize: stillResource.pixelSize ?? .zero,
          duration: pairedVideoResource.duration ?? 0,
          stillImageContentTypeIdentifier: stillResource.contentType,
          pairedVideoContentTypeIdentifier: pairedVideoResource.contentType,
          stillImageByteSize: stillResource.byteSize,
          pairedVideoByteSize: pairedVideoResource.byteSize
        ),
        location: location
      )
    case .audio:
      let fileURL = try mediaFileURL(matching: JournalVault.Attachment.Kind.audio)
      let editableURL = try VaultSavedEntryEditMediaPreparer.audioCopy(from: fileURL)
      return CardEditDraft(
        kind: .audio,
        audio: AudioRecording(
          fileURL: editableURL,
          duration: VaultSavedEntryEditMediaPreparer.audioDuration(from: editableURL)
        ),
        location: location
      )
    case .suggestion:
      let data = try await mediaData(matching: .suggestion)
      guard let suggestion = SuggestionCardPayload.decode(from: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .suggestion,
        suggestion: suggestion,
        suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID(for: suggestion),
        location: location
      )
    case .doodle:
      let data = try await mediaData(matching: .doodle)
      guard let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(kind: .doodle, doodle: drawing, location: location)
    case .bauhaus:
      let data = try await mediaData(matching: .bauhaus)
      guard let document = try? JSONDecoder().decode(BauhausGridDocument.self, from: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(kind: .bauhaus, bauhaus: document, location: location)
    case .unknown:
      throw VaultSavedEntryEditDraftError.unsupportedKind
    @unknown default:
      throw VaultSavedEntryEditDraftError.unsupportedKind
    }
  }

  private func mediaFileURL(matching kind: JournalVault.Attachment.Kind) throws -> URL {
    guard attachment?.kind == kind,
          let fileURL = attachment?.fileURL,
          FileManager.default.fileExists(atPath: fileURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return fileURL
  }

  private func mediaFileURL(matching role: JournalVault.AttachmentResource.Role) throws -> URL {
    let resource = try mediaResource(matching: role)
    guard FileManager.default.fileExists(atPath: resource.fileURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource.fileURL
  }

  private func mediaResource(matching role: JournalVault.AttachmentResource.Role) throws -> VaultSavedAttachmentResource {
    guard let resource = attachment?.resources.first(where: { $0.role == role }) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource
  }

  private func mediaData(matching kind: JournalVault.Attachment.Kind) async throws -> Data {
    let fileURL = try mediaFileURL(matching: kind)
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func mediaData(matching role: JournalVault.AttachmentResource.Role) async throws -> Data {
    let fileURL = try mediaFileURL(matching: role)
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func suggestionMediaFileURLsByResourceID(
    for suggestion: SuggestionCardPayload
  ) -> [UUID: URL] {
    guard let attachment else { return [:] }

    let resourcesByID = Dictionary(uniqueKeysWithValues: attachment.resources.map { ($0.id, $0.fileURL) })
    return suggestion.mediaResources.reduce(into: [UUID: URL]()) { result, media in
      guard let resourceID = media.resourceID,
            let fileURL = resourcesByID[resourceID],
            FileManager.default.fileExists(atPath: fileURL.path) else {
        return
      }
      result[resourceID] = fileURL
    }
  }
}

private struct VaultSavedAttachment {

  let id: UUID
  let kind: JournalVault.Attachment.Kind
  let byteSize: Int
  let primaryResourceID: UUID
  let fileURL: URL
  let fileRevision: Int
  let thumbnail: Data?
  let resources: [VaultSavedAttachmentResource]

  init?(attachment: JournalVault.Attachment, store: VaultContentStore) {
    let resources = attachment.resources
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .map { VaultSavedAttachmentResource(resource: $0, store: store) }

    guard let primaryResource = resources.first(where: { $0.id == attachment.primaryResourceID }) else {
      return nil
    }

    self.id = attachment.id
    self.kind = attachment.kind
    self.byteSize = attachment.byteSize
    self.primaryResourceID = attachment.primaryResourceID
    self.fileURL = primaryResource.fileURL
    self.fileRevision = resources.reduce(0) { $0 &+ $1.localFileRevision }
    self.thumbnail = attachment.thumbnail
    self.resources = resources
  }

  var primaryResource: VaultSavedAttachmentResource? {
    resources.first { $0.id == primaryResourceID }
  }
}

private struct VaultSavedAttachmentResource {

  let id: UUID
  let role: JournalVault.AttachmentResource.Role
  let byteSize: Int
  let contentType: String?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let duration: Double?
  let fileURL: URL
  let localFileRevision: Int

  init(resource: JournalVault.AttachmentResource, store: VaultContentStore) {
    self.id = resource.id
    self.role = resource.role
    self.byteSize = resource.byteSize
    self.contentType = resource.contentType
    self.pixelWidth = resource.pixelWidth
    self.pixelHeight = resource.pixelHeight
    self.duration = resource.duration
    self.fileURL = store.fileURL(for: resource)
    self.localFileRevision = resource.localFileRevision
  }

  var pixelSize: CGSize? {
    guard let pixelWidth, let pixelHeight else {
      return nil
    }

    return CGSize(width: pixelWidth, height: pixelHeight)
  }
}

/// Errors surfaced when a saved vault entry cannot be reopened as an editable draft.
private enum VaultSavedEntryEditDraftError: LocalizedError {
  case vaultUnavailable
  case mediaUnavailable
  case mediaDecodeFailed
  case mediaCopyFailed
  case unsupportedKind

  var errorDescription: String? {
    switch self {
    case .vaultUnavailable:
      return String(localized: "The selected vault is not available.")
    case .mediaUnavailable:
      return String(localized: "This card's media file is not available on this device yet.")
    case .mediaDecodeFailed:
      return String(localized: "This card's media file could not be read for editing.")
    case .mediaCopyFailed:
      return String(localized: "This card's media file could not be prepared for editing.")
    case .unsupportedKind:
      return String(localized: "This card type is not editable yet.")
    }
  }
}

/// File I/O shared by saved-entry edit rehydration.
private enum VaultSavedEntryMediaFileReader {
  nonisolated static func data(from fileURL: URL) async -> Data? {
    await Task.detached(priority: .utility) {
      try? Data(contentsOf: fileURL)
    }.value
  }
}

/// File preparation needed before persisted media can re-enter the edit pipeline.
private enum VaultSavedEntryEditMediaPreparer {

  @MainActor
  static func audioCopy(from sourceURL: URL) throws -> URL {
    try mediaCopy(from: sourceURL, fallbackPathExtension: "m4a")
  }

  @MainActor
  static func mediaCopy(
    from sourceURL: URL,
    fallbackPathExtension: String
  ) throws -> URL {
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }

    let pathExtension = sourceURL.pathExtension.isEmpty ? fallbackPathExtension : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("journal-vault-edit-media-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)

    do {
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    } catch {
      throw VaultSavedEntryEditDraftError.mediaCopyFailed
    }
  }

  @MainActor
  static func audioDuration(from fileURL: URL) -> TimeInterval {
    (try? AVAudioPlayer(contentsOf: fileURL).duration) ?? 0
  }
}

private struct VaultSavedDaySection: Identifiable {
  let id: Date
  let day: Date
  var entries: [VaultSavedEntry]

  static func sections(
    for entries: [VaultSavedEntry],
    calendar: Calendar
  ) -> [VaultSavedDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [VaultSavedDaySection] = []

    for entry in entries {
      let day = calendar.startOfDay(for: entry.createdAt)
      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].entries.append(entry)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(VaultSavedDaySection(id: day, day: day, entries: [entry]))
      }
    }

    return sections
  }
}

// MARK: - Layout

private enum SavedListGrid {
  static func columns(for horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
    if horizontalSizeClass == .compact {
      return [
        GridItem(.flexible(), spacing: cardSpacing),
        GridItem(.flexible(), spacing: cardSpacing),
      ]
    }

    return [
      GridItem(
        .adaptive(minimum: regularMinimumCardWidth, maximum: regularMaximumCardWidth),
        spacing: cardSpacing
      )
    ]
  }
}

private let cardSpacing: CGFloat = 16
private let daySectionSpacing: CGFloat = 28
private let dayHeaderSpacing: CGFloat = 12
private let regularMinimumCardWidth: CGFloat = 168
private let regularMaximumCardWidth: CGFloat = 220
private let detailScreenPadding: CGFloat = 16
private let detailMaximumCardWidth: CGFloat = 520

// MARK: - Views

/// Modal editor for an existing vault card.
///
/// The sheet owns cancellation chrome while `CardEditDraftEditor` owns the
/// card-specific editing controls. Saving is lifted to `SavedListView` so the
/// selected vault, reload, and outbox refresh all happen at the screen boundary.
private struct VaultSavedEntryEditSheet: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let onSave: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  var body: some View {
    NavigationStack {
      CardEditDraftEditor(
        draft: draft,
        isSaving: isSaving,
        confirmationTitle: "Save",
        showsKindPicker: false,
        onConfirm: onSave
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
          .disabled(isSaving)
        }
      }
    }
  }
}

private struct VaultSavedDaySectionView: View {

  let section: VaultSavedDaySection
  let columns: [GridItem]
  let childEntriesByParentID: [UUID: [VaultSavedEntry]]
  let areStacksExpanded: Bool
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let stackExpansionNamespace: Namespace.ID
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool

  @State private var deleteCandidate: VaultSavedEntry?

  var body: some View {
    VStack(alignment: .leading, spacing: dayHeaderSpacing) {
      VaultSavedDayHeader(day: section.day)

      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(section.entries) { entry in
          let subtree = subtreeEntries(startingAt: entry)
          let childEntries = Array(subtree.dropFirst())

          NavigationLink {
            VaultSavedEntryDetailView(
              entries: subtree,
              rootTitle: entry.kind.vaultListDisplayTitle,
              isEditingDisabled: isEditingDisabled,
              isDeletingDisabled: isDeletingDisabled,
              onShare: onShare,
              onEdit: onEdit,
              onDelete: onDelete
            )
            .journalZoomNavigationTransition(sourceID: entry.edgeID, in: transitionNamespace)
          } label: {
            VaultSavedEntryStackTile(
              entry: entry,
              childEntries: childEntries,
              isExpanded: areStacksExpanded,
              stackNamespace: stackExpansionNamespace,
              transitionNamespace: transitionNamespace
            )
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button {
              onShare(entry)
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
              onEdit(entry)
            } label: {
              Label("Edit", systemImage: "square.and.pencil")
            }
            .disabled(isEditingDisabled)

            Button(role: .destructive) {
              deleteCandidate = entry
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .disabled(isDeletingDisabled)
          }
        }
      }
    }
    .confirmationDialog(
      "Delete Card",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Card", role: .destructive) {
        deleteCandidate = nil
        Task { @MainActor in
          _ = await onDelete(entry)
        }
      }
      Button("Cancel", role: .cancel) {
        deleteCandidate = nil
      }
    } message: { _ in
      Text("This card and any connected cards will be removed from this vault. Synced copies are deleted through iCloud.")
    }
  }

  private var deleteConfirmationPresentation: Binding<Bool> {
    Binding {
      deleteCandidate != nil
    } set: { isPresented in
      if isPresented == false {
        deleteCandidate = nil
      }
    }
  }

  private func subtreeEntries(startingAt root: VaultSavedEntry) -> [VaultSavedEntry] {
    var result = [root]

    func appendChildren(of parentID: UUID) {
      for child in childEntriesByParentID[parentID] ?? [] {
        result.append(child)
        appendChildren(of: child.edgeID)
      }
    }

    appendChildren(of: root.edgeID)
    return result
  }
}

private struct VaultSavedDayHeader: View {

  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
  }
}

private struct VaultSavedEntryStackTile: View {

  let entry: VaultSavedEntry
  let childEntries: [VaultSavedEntry]
  let isExpanded: Bool
  let stackNamespace: Namespace.ID
  let transitionNamespace: Namespace.ID

  var body: some View {
    ZStack {
      if isExpanded == false {
        ForEach(childEntries.prefix(2).indexed(), id: \.element.edgeID) { index, child in
          VaultSavedEntryTile(entry: child.cardModel, childCount: 0)
            .matchedGeometryEffect(id: child.edgeID, in: stackNamespace)
            .scaleEffect(1 - CGFloat(index + 1) * 0.035)
            .offset(x: CGFloat(index + 1) * 4, y: CGFloat(index + 1) * 6)
            .opacity(0.72 - CGFloat(index) * 0.18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }

      VaultSavedEntryTile(
        entry: entry.cardModel,
        childCount: childEntries.count
      )
      .matchedGeometryEffect(id: entry.edgeID, in: stackNamespace)
      .journalMatchedTransitionSource(id: entry.edgeID, in: transitionNamespace)
    }
  }
}

private struct VaultSavedEntryDetailView: View {

  let entries: [VaultSavedEntry]
  let rootTitle: LocalizedStringResource
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var deleteCandidate: VaultSavedEntry?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .center, spacing: 24) {
        ForEach(entries) { entry in
          VaultSavedEntryDetailCard(
            entry: entry.cardModel,
            isEditingDisabled: isEditingDisabled,
            isDeletingDisabled: isDeletingDisabled,
            onEdit: {
              onEdit(entry)
            },
            onDelete: {
              deleteCandidate = entry
            }
          )
          .contextMenu {
            Button {
              onShare(entry)
            } label: {
              Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
              onEdit(entry)
            } label: {
              Label("Edit", systemImage: "square.and.pencil")
            }
            .disabled(isEditingDisabled)

            Button(role: .destructive) {
              deleteCandidate = entry
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .disabled(isDeletingDisabled)
          }
          .frame(maxWidth: detailMaximumCardWidth)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(detailScreenPadding)
    }
    .background(.background)
    .navigationTitle(rootTitle)
    .journalInlineNavigationTitle()
    .confirmationDialog(
      "Delete Card",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Card", role: .destructive) {
        deleteCandidate = nil
        Task { @MainActor in
          let didDelete = await onDelete(entry)
          if didDelete {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {
        deleteCandidate = nil
      }
    } message: { _ in
      Text("This card and any connected cards will be removed from this vault. Synced copies are deleted through iCloud.")
    }
  }

  private var deleteConfirmationPresentation: Binding<Bool> {
    Binding {
      deleteCandidate != nil
    } set: { isPresented in
      if isPresented == false {
        deleteCandidate = nil
      }
    }
  }
}

private extension VaultSavedEntry {

  /// Detached values handed to the share/export feature.
  ///
  /// The share sheet renders temporary files from this value copy, so it never
  /// holds a live SwiftData model or reaches back into the selected vault.
  var shareSource: CardShareSource {
    CardShareSource(
      id: edgeID,
      kind: kind,
      body: body,
      createdAt: createdAt,
      location: location,
      attachment: attachment?.shareSource
    )
  }

  /// Display projection handed to `AppUIComponents`.
  ///
  /// The saved-list feature owns live vault models and mutation callbacks; the
  /// UI component module receives only the stable values it needs to render a card.
  var cardModel: VaultSavedEntryCardModel {
    VaultSavedEntryCardModel(
      id: edgeID,
      kind: kind,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      location: location,
      attachment: attachment?.cardModel
    )
  }
}

private extension VaultSavedAttachment {

  var shareSource: CardShareAttachmentSource {
    CardShareAttachmentSource(
      kind: kind,
      fileURL: fileURL,
      thumbnail: thumbnail
    )
  }

  var cardModel: VaultSavedEntryAttachmentModel {
    VaultSavedEntryAttachmentModel(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: resources.first { $0.role == .pairedVideo }?.fileURL,
      fileRevision: fileRevision,
      thumbnail: thumbnail,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }

  private var suggestionMediaFileURLsByResourceID: [UUID: URL] {
    resources.reduce(into: [UUID: URL]()) { result, resource in
      switch resource.role {
      case .suggestionImage, .suggestionVideo:
        result[resource.id] = resource.fileURL
      case .originalImage,
        .stillImage,
        .pairedVideo,
        .originalVideo,
        .authoredJSON,
        .audio,
        .unknown:
        break
      @unknown default:
        break
      }
    }
  }
}

// MARK: - Sorting

private extension Array where Element == VaultSavedEntry {

  func sortedForVaultList() -> [VaultSavedEntry] {
    sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }

  func sortedForVaultListSiblings() -> [VaultSavedEntry] {
    sorted { lhs, rhs in
      if lhs.sortIndex != rhs.sortIndex {
        return lhs.sortIndex < rhs.sortIndex
      }
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }
}

private extension UIImage {

  /// Pixel dimensions for persistence metadata derived from reloaded image data.
  var pixelSize: CGSize {
    CGSize(width: size.width * scale, height: size.height * scale)
  }
}
