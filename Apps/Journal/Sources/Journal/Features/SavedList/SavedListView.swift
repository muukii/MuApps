import AVFoundation
import Algorithms
import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import JournalVault
import MapKit
import MuColor
import SwiftData
import SwiftUI
import WidgetKit

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Vault-backed entries list.
///
/// This screen intentionally reads only the selected `VaultInstance`. It does
/// not receive any legacy persistence container; legacy data enters the current
/// UI only after the sync layer has imported it into a vault store.
struct SavedListView: View {

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @Binding private var scrollTargetID: UUID?

  init(scrollTargetID: Binding<UUID?> = .constant(nil)) {
    _scrollTargetID = scrollTargetID
  }

  var body: some View {
    Group {
      if let vault = vaultRuntime.selectedVault,
        vaultRuntime.selectedVaultState == .active
      {
        VaultSavedListContentView(
          vault: vault,
          scrollTargetID: $scrollTargetID
        )
        .modelContainer(vault.contentStore.container)
      } else {
        ContentUnavailableView("Vault Not Ready", systemImage: "externaldrive")
      }
    }
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

  @Binding var scrollTargetID: UUID?

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

  @State private var sharePreviewPresentation: EntrySharePreviewPresentation?
  @State private var editPresentation: VaultSavedEntryEditPresentation?
  @State private var isEditDraftLoading = false
  @State private var isSavingEdit = false
  @State private var isDeletingEntry = false
  @State private var editErrorMessage: String?
  @State private var deleteErrorMessage: String?
  @Namespace private var navigationTransitionNamespace

  var body: some View {
    let entries = entries
    let edgeIDs = Set(entries.map(\.edgeID))
    let columns = SavedListGrid.columns(for: horizontalSizeClass)
    let isMutationDisabled = isEditDraftLoading || isSavingEdit || isDeletingEntry
    let visibleSections = VaultSavedDaySection.sections(
      for: entries.sortedForVaultList(),
      calendar: calendar
    )
    let childEntriesByParentID = Self.childEntriesByParentID(
      for: entries,
      edgeIDs: edgeIDs
    )
    let locationPins = Self.savedLocationPins(for: entries)

    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: daySectionSpacing) {
          if locationPins.isEmpty == false {
            VaultSavedLocationsMapNavigationHeader(
              pins: locationPins,
              transitionNamespace: navigationTransitionNamespace
            )
          }

          ForEach(visibleSections) { section in
            VaultSavedDaySectionView(
              section: section,
              columns: columns,
              childEntriesByParentID: childEntriesByParentID,
              isEditingDisabled: isMutationDisabled,
              isDeletingDisabled: isMutationDisabled,
              transitionNamespace: navigationTransitionNamespace,
              onShare: presentSharePreview,
              onEdit: presentEditDraft,
              onDelete: deleteEntry
            )
          }
        }
        .padding(cardSpacing)
      }
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .scrollDismissesKeyboard(.interactively)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onChange(of: scrollTargetID, initial: true) { _, _ in
        scrollToPendingEntry(using: proxy, availableEdgeIDs: edgeIDs)
      }
      .onChange(of: edgeIDs) { _, _ in
        scrollToPendingEntry(using: proxy, availableEdgeIDs: edgeIDs)
      }
    }
    .overlay {
      if visibleSections.isEmpty {
        ContentUnavailableView("No Entries", systemImage: "book.closed")
          .allowsHitTesting(false)
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .refreshable {
      await vaultRuntime.refresh()
    }
    .sheet(item: $sharePreviewPresentation) { presentation in
      EntrySharePreviewScreen(
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
    .alert("Could Not Edit Entry", isPresented: editErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let editErrorMessage {
        Text(editErrorMessage)
      }
    }
    .alert("Could Not Delete Entry", isPresented: deleteErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let deleteErrorMessage {
        Text(deleteErrorMessage)
      }
    }
  }

  /// Groups child placements once for the current query snapshot.
  private static func childEntriesByParentID(
    for entries: [VaultSavedEntry],
    edgeIDs: Set<UUID>
  ) -> [UUID: [VaultSavedEntry]] {
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

  /// Location annotations for every unique saved card in the selected vault.
  ///
  /// Location belongs to the authored card rather than its placement edge, so
  /// the stable card id owns the pin. The dictionary also prevents a transient
  /// duplicate placement during graph repair from drawing the same card twice.
  private static func savedLocationPins(
    for entries: [VaultSavedEntry]
  ) -> [VaultSavedLocationPin] {
    var pinsByCardID: [UUID: VaultSavedLocationPin] = [:]

    for entry in entries {
      guard let coordinate = entry.location else { continue }
      pinsByCardID[entry.cardID] = VaultSavedLocationPin(
        id: entry.cardID,
        coordinate: coordinate,
        createdAt: entry.createdAt
      )
    }

    return pinsByCardID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }

  /// Scrolls after the posted edge has reached this view's live SwiftData query.
  /// Keeping the request pending until then avoids racing persistence with the
  /// lazy grid's view construction.
  private func scrollToPendingEntry(
    using proxy: ScrollViewProxy,
    availableEdgeIDs: Set<UUID>
  ) {
    guard let targetID = scrollTargetID, availableEdgeIDs.contains(targetID) else {
      return
    }

    withAnimation(.smooth) {
      proxy.scrollTo(targetID, anchor: .top)
    }
    scrollTargetID = nil
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
    sharePreviewPresentation = EntrySharePreviewPresentation(
      snapshot: EntryShareSnapshot(source: entry.shareSource),
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
private struct EntrySharePreviewPresentation: Identifiable {
  let id = UUID()
  let snapshot: EntryShareSnapshot
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

/// Stable display value for one saved card's geographic annotation.
///
/// Map views intentionally receive this detached value instead of live SwiftData
/// models. The selected-vault query owns observation; map rendering only needs a
/// card identity, coordinate, and creation time.
private struct VaultSavedLocationPin: Identifiable, Hashable {
  let id: UUID
  let coordinate: JournalVault.Coordinate
  let createdAt: Date
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
    case .file:
      // Generic file cards preserve arbitrary bytes and metadata, but the
      // composer does not yet expose a lossless file-replacement editor.
      throw VaultSavedEntryEditDraftError.unsupportedKind
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
      FileManager.default.fileExists(atPath: fileURL.path)
    else {
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

  private func mediaResource(matching role: JournalVault.AttachmentResource.Role) throws
    -> VaultSavedAttachmentResource
  {
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

    let resourcesByID = Dictionary(
      uniqueKeysWithValues: attachment.resources.map { ($0.id, $0.fileURL) })
    return suggestion.mediaResources.reduce(into: [UUID: URL]()) { result, media in
      guard let resourceID = media.resourceID,
        let fileURL = resourcesByID[resourceID],
        FileManager.default.fileExists(atPath: fileURL.path)
      else {
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

    guard let primaryResource = resources.first(where: { $0.id == attachment.primaryResourceID })
    else {
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
      return String(localized: "This entry's media file is not available on this device yet.")
    case .mediaDecodeFailed:
      return String(localized: "This entry's media file could not be read for editing.")
    case .mediaCopyFailed:
      return String(localized: "This entry's media file could not be prepared for editing.")
    case .unsupportedKind:
      return String(localized: "This content type is not editable yet.")
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

    let pathExtension =
      sourceURL.pathExtension.isEmpty ? fallbackPathExtension : sourceURL.pathExtension
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
private let detailMaximumContentWidth: CGFloat = 720
private let savedLocationsMapHeaderHeight: CGFloat = 136
private let savedLocationsMapCornerRadius: CGFloat = 22

// MARK: - Views

/// Modal editor for an existing vault card.
///
/// The sheet owns cancellation chrome while `EntryDraftEditor` owns the
/// card-specific editing controls. Saving is lifted to `SavedListView` so the
/// selected vault, reload, and outbox refresh all happen at the screen boundary.
private struct VaultSavedEntryEditSheet: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let onSave: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  var body: some View {
    NavigationStack {
      EntryDraftEditor(
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

/// Tappable geographic header shown before the saved-card day sections.
private struct VaultSavedLocationsMapNavigationHeader: View {

  let pins: [VaultSavedLocationPin]
  let transitionNamespace: Namespace.ID

  var body: some View {
    NavigationLink {
      VaultSavedLocationsMapView(pins: pins)
        .appZoomNavigationTransition(
          sourceID: VaultSavedLocationsMapTransition.id,
          in: transitionNamespace
        )
    } label: {
      VaultSavedLocationsMapHeader(pins: pins)
    }
    .buttonStyle(.plain)
    .appMatchedTransitionSource(
      id: VaultSavedLocationsMapTransition.id,
      in: transitionNamespace
    )
    .accessibilityLabel("Open Map")
    .accessibilityValue(
      Text(
        "Saved locations: \(pins.count)",
        comment:
          "Accessibility value for the saved-entry map; the variable is the number of location pins."
      )
    )
  }
}

/// Compact, zoomed-in map that keeps the saved cards visible below it.
private struct VaultSavedLocationsMapHeader: View {

  let pins: [VaultSavedLocationPin]

  var body: some View {
    ZStack {
      Map(
        initialPosition: VaultSavedLocationsMapCamera.headerPosition(for: pins),
        interactionModes: []
      ) {
        ForEach(pins.dropFirst()) { pin in
          Annotation("Saved Entry", coordinate: pin.coordinate.clCoordinate) {
            VaultSavedLocationPinMarker(pin: pin, markerSize: 24)
          }
          .annotationTitles(.hidden)
        }
      }
      // A newly posted located card becomes the header's camera subject. Keep
      // ordinary sync changes stable, but rebuild when that latest pin changes.
      .id(pins.first)
      .mapStyle(.standard(elevation: .flat))
      .mapControlVisibility(.hidden)
      .allowsHitTesting(false)

      if let latestPin = pins.first {
        VaultSavedLocationPinMarker(pin: latestPin, markerSize: 28)
      }
    }
    .overlay(alignment: .topTrailing) {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnPrimaryContainer)
        .frame(width: 32, height: 32)
        .background(.appPrimaryContainer.opacity(0.94), in: Circle())
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .padding(10)
        .accessibilityHidden(true)
    }
    .frame(height: savedLocationsMapHeaderHeight)
    .clipShape(.rect(cornerRadius: savedLocationsMapCornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: savedLocationsMapCornerRadius, style: .continuous)
        .stroke(.appOnPrimaryContainer.opacity(0.12), lineWidth: 1)
    }
    .contentShape(.rect(cornerRadius: savedLocationsMapCornerRadius, style: .continuous))
  }
}

/// Interactive overview that initially frames every saved-card location pin.
private struct VaultSavedLocationsMapView: View {

  @Environment(\.appPalette) private var palette

  let pins: [VaultSavedLocationPin]

  var body: some View {
    VaultSavedLocationsClusterMap(
      pins: pins,
      markerColor: palette.tint,
      glyphColor: palette.onTint
    )
    .navigationTitle("Map")
    .appInlineNavigationTitle()
  }
}

#if canImport(UIKit)
  /// Platform representable protocol used by the clustered map on iOS.
  private typealias VaultSavedLocationsMapRepresentable = UIViewRepresentable
  /// Platform color consumed by MapKit annotation views on iOS.
  private typealias VaultSavedLocationsMapPlatformColor = UIColor
#else
  /// Platform representable protocol used by the clustered map on macOS.
  private typealias VaultSavedLocationsMapRepresentable = NSViewRepresentable
  /// Platform color consumed by MapKit annotation views on macOS.
  private typealias VaultSavedLocationsMapPlatformColor = NSColor
#endif

/// Native MapKit bridge that enables automatic annotation clustering.
private struct VaultSavedLocationsClusterMap: VaultSavedLocationsMapRepresentable {

  let pins: [VaultSavedLocationPin]
  let markerColor: Color
  let glyphColor: Color

  func makeCoordinator() -> VaultSavedLocationsMapCoordinator {
    VaultSavedLocationsMapCoordinator()
  }

  #if canImport(UIKit)
    func makeUIView(context: Context) -> MKMapView {
      makeMapView(context: context)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
      update(mapView, context: context)
    }

    static func dismantleUIView(
      _ mapView: MKMapView,
      coordinator: VaultSavedLocationsMapCoordinator
    ) {
      mapView.delegate = nil
    }
  #else
    func makeNSView(context: Context) -> MKMapView {
      makeMapView(context: context)
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
      update(mapView, context: context)
    }

    static func dismantleNSView(
      _ mapView: MKMapView,
      coordinator: VaultSavedLocationsMapCoordinator
    ) {
      mapView.delegate = nil
    }
  #endif

  private func makeMapView(context: Context) -> MKMapView {
    let mapView = MKMapView(frame: .zero)
    context.coordinator.install(on: mapView)
    update(mapView, context: context)
    return mapView
  }

  private func update(_ mapView: MKMapView, context: Context) {
    context.coordinator.update(
      pins: pins,
      markerColor: platformColor(markerColor),
      glyphColor: platformColor(glyphColor),
      on: mapView
    )
  }

  private func platformColor(_ color: Color) -> VaultSavedLocationsMapPlatformColor {
    #if canImport(UIKit)
      UIColor(color)
    #else
      NSColor(color)
    #endif
  }
}

/// MapKit delegate and annotation store for the interactive saved-locations map.
@MainActor
private final class VaultSavedLocationsMapCoordinator: NSObject, MKMapViewDelegate {

  private static let pinReuseIdentifier = "VaultSavedLocationPin"
  private static let clusteringIdentifier = "VaultSavedLocation"
  private static let overviewEdgePadding: CGFloat = 48

  private var annotationsByID: [UUID: VaultSavedLocationMapPoint] = [:]
  private var hasFittedInitialPins = false
  private var markerColor: VaultSavedLocationsMapPlatformColor
  private var glyphColor: VaultSavedLocationsMapPlatformColor

  override init() {
    #if canImport(UIKit)
      markerColor = .systemBlue
      glyphColor = .white
    #else
      markerColor = .controlAccentColor
      glyphColor = .white
    #endif
    super.init()
  }

  func install(on mapView: MKMapView) {
    mapView.delegate = self
    mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
    mapView.register(
      VaultSavedLocationMarkerAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: Self.pinReuseIdentifier
    )
    mapView.register(
      VaultSavedLocationClusterAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
    )
  }

  func update(
    pins: [VaultSavedLocationPin],
    markerColor: VaultSavedLocationsMapPlatformColor,
    glyphColor: VaultSavedLocationsMapPlatformColor,
    on mapView: MKMapView
  ) {
    self.markerColor = markerColor
    self.glyphColor = glyphColor

    let desiredIDs = Set(pins.map(\.id))
    let removedAnnotations = annotationsByID.compactMap { id, annotation in
      desiredIDs.contains(id) ? nil : annotation
    }
    for annotation in removedAnnotations {
      annotationsByID[annotation.id] = nil
    }
    mapView.removeAnnotations(removedAnnotations)

    var newAnnotations: [VaultSavedLocationMapPoint] = []
    for pin in pins {
      if let annotation = annotationsByID[pin.id] {
        annotation.update(from: pin)
      } else {
        let annotation = VaultSavedLocationMapPoint(pin: pin)
        annotationsByID[pin.id] = annotation
        newAnnotations.append(annotation)
      }
    }
    mapView.addAnnotations(newAnnotations)
    refreshVisibleAnnotationViews(on: mapView)

    guard hasFittedInitialPins == false, pins.isEmpty == false else { return }
    fitInitialPins(pins, on: mapView)
    hasFittedInitialPins = true
  }

  func mapView(
    _ mapView: MKMapView,
    viewFor annotation: any MKAnnotation
  ) -> MKAnnotationView? {
    guard annotation is MKUserLocation == false else { return nil }

    if let cluster = annotation as? MKClusterAnnotation {
      guard
        let view = mapView.dequeueReusableAnnotationView(
          withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
          for: cluster
        ) as? VaultSavedLocationClusterAnnotationView
      else {
        return nil
      }
      configure(view, for: cluster)
      return view
    }

    guard let point = annotation as? VaultSavedLocationMapPoint,
      let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: Self.pinReuseIdentifier,
        for: point
      ) as? VaultSavedLocationMarkerAnnotationView
    else {
      return nil
    }
    configure(view, for: point)
    return view
  }

  private func configure(
    _ view: MKMarkerAnnotationView,
    for annotation: any MKAnnotation
  ) {
    view.markerTintColor = markerColor
    view.glyphTintColor = glyphColor
    view.canShowCallout = false
    view.collisionMode = .circle

    if let cluster = annotation as? MKClusterAnnotation {
      view.clusteringIdentifier = nil
      view.displayPriority = .required
      view.glyphImage = nil
      view.glyphText = cluster.memberAnnotations.count.formatted()
      setAccessibilityLabel(
        String(localized: "Saved entries: \(cluster.memberAnnotations.count)"),
        on: view
      )
    } else {
      view.clusteringIdentifier = Self.clusteringIdentifier
      view.displayPriority = .defaultHigh
      view.glyphText = nil
      #if canImport(UIKit)
        view.glyphImage = UIImage(systemName: "mappin")
      #else
        view.glyphImage = NSImage(
          systemSymbolName: "mappin",
          accessibilityDescription: String(localized: "Saved Entry")
        )
      #endif
      setAccessibilityLabel(String(localized: "Saved Entry"), on: view)
    }
  }

  private func refreshVisibleAnnotationViews(on mapView: MKMapView) {
    for annotation in mapView.annotations {
      guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else {
        continue
      }
      configure(view, for: annotation)
    }
  }

  private func fitInitialPins(
    _ pins: [VaultSavedLocationPin],
    on mapView: MKMapView
  ) {
    if pins.count == 1, let pin = pins.first {
      mapView.setRegion(
        VaultSavedLocationsMapCamera.singlePinRegion(for: pin),
        animated: false
      )
      return
    }

    guard let mapRect = VaultSavedLocationsMapCamera.overviewMapRect(for: pins) else {
      return
    }

    #if canImport(UIKit)
      let edgePadding = UIEdgeInsets(
        top: Self.overviewEdgePadding,
        left: Self.overviewEdgePadding,
        bottom: Self.overviewEdgePadding,
        right: Self.overviewEdgePadding
      )
    #else
      let edgePadding = NSEdgeInsets(
        top: Self.overviewEdgePadding,
        left: Self.overviewEdgePadding,
        bottom: Self.overviewEdgePadding,
        right: Self.overviewEdgePadding
      )
    #endif
    mapView.setVisibleMapRect(
      mapRect,
      edgePadding: edgePadding,
      animated: false
    )
  }

  private func setAccessibilityLabel(
    _ label: String,
    on view: MKAnnotationView
  ) {
    #if canImport(UIKit)
      view.accessibilityLabel = label
    #else
      view.setAccessibilityLabel(label)
    #endif
  }
}

/// Mutable MapKit annotation retained across SwiftUI representable updates.
private nonisolated final class VaultSavedLocationMapPoint: MKPointAnnotation {

  let id: UUID
  private(set) var createdAt: Date

  init(pin: VaultSavedLocationPin) {
    id = pin.id
    createdAt = pin.createdAt
    super.init()
    update(from: pin)
  }

  func update(from pin: VaultSavedLocationPin) {
    if coordinate.latitude != pin.coordinate.latitude
      || coordinate.longitude != pin.coordinate.longitude
    {
      coordinate = pin.coordinate.clCoordinate
    }
    createdAt = pin.createdAt
    title = String(localized: "Saved Entry")
  }
}

/// Reusable marker view that opts each saved-card annotation into clustering.
private final class VaultSavedLocationMarkerAnnotationView: MKMarkerAnnotationView {

  override init(
    annotation: (any MKAnnotation)?,
    reuseIdentifier: String?
  ) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    clusteringIdentifier = "VaultSavedLocation"
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    clusteringIdentifier = "VaultSavedLocation"
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    clusteringIdentifier = "VaultSavedLocation"
    glyphImage = nil
    glyphText = nil
  }
}

/// Count marker produced automatically when saved-card annotations collide.
private final class VaultSavedLocationClusterAnnotationView: MKMarkerAnnotationView {

  override func prepareForDisplay() {
    super.prepareForDisplay()
    clusteringIdentifier = nil
    glyphImage = nil
    if let cluster = annotation as? MKClusterAnnotation {
      let memberCount = cluster.memberAnnotations.count
      let accessibilityLabel = String(localized: "Saved entries: \(memberCount)")
      glyphText = memberCount.formatted()
      #if canImport(UIKit)
        self.accessibilityLabel = accessibilityLabel
      #else
        setAccessibilityLabel(accessibilityLabel)
      #endif
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    glyphImage = nil
    glyphText = nil
  }
}

/// Location pin that remains legible over both light and dark map tiles.
private struct VaultSavedLocationPinMarker: View {

  let pin: VaultSavedLocationPin
  let markerSize: CGFloat

  var body: some View {
    Image(systemName: "mappin")
      .font(.system(size: markerSize * 0.48, weight: .semibold))
      .foregroundStyle(.appOnTint)
      .frame(width: markerSize, height: markerSize)
      .background(Color.accentColor, in: Circle())
      .overlay {
        Circle()
          .stroke(.white.opacity(0.88), lineWidth: 1.5)
      }
      .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
      .accessibilityLabel("Saved Entry")
      .accessibilityValue(
        Text(pin.createdAt, format: .dateTime.year().month().day().hour().minute())
      )
  }
}

/// Camera policies for the zoomed header and the all-pins overview.
private enum VaultSavedLocationsMapCamera {

  private static let headerSpanMeters: CLLocationDistance = 1_200
  private static let minimumOverviewSpanMeters: CLLocationDistance = 1_200
  private static let overviewPaddingScale: Double = 1.5

  static func headerPosition(for pins: [VaultSavedLocationPin]) -> MapCameraPosition {
    guard let latestPin = pins.first else {
      return .automatic
    }

    return .region(
      MKCoordinateRegion(
        center: latestPin.coordinate.clCoordinate,
        latitudinalMeters: headerSpanMeters,
        longitudinalMeters: headerSpanMeters
      )
    )
  }

  static func singlePinRegion(for pin: VaultSavedLocationPin) -> MKCoordinateRegion {
    MKCoordinateRegion(
      center: pin.coordinate.clCoordinate,
      latitudinalMeters: minimumOverviewSpanMeters,
      longitudinalMeters: minimumOverviewSpanMeters
    )
  }

  static func overviewMapRect(for pins: [VaultSavedLocationPin]) -> MKMapRect? {
    guard let firstPin = pins.first, pins.count > 1 else { return nil }

    let pinRect = pins.reduce(into: MKMapRect.null) { mapRect, pin in
      let point = MKMapPoint(pin.coordinate.clCoordinate)
      let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
      mapRect = mapRect.union(pointRect)
    }
    let minimumSpan =
      minimumOverviewSpanMeters
      * MKMapPointsPerMeterAtLatitude(firstPin.coordinate.latitude)
    let width = max(pinRect.width * overviewPaddingScale, minimumSpan)
    let height = max(pinRect.height * overviewPaddingScale, minimumSpan)

    return MKMapRect(
      x: pinRect.midX - width / 2,
      y: pinRect.midY - height / 2,
      width: width,
      height: height
    )
  }
}

/// Stable transition identity shared by the map header and overview.
private enum VaultSavedLocationsMapTransition {
  static let id = "saved-locations-map"
}

private struct VaultSavedDaySectionView: View {

  let section: VaultSavedDaySection
  let columns: [GridItem]
  let childEntriesByParentID: [UUID: [VaultSavedEntry]]
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
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
          NavigationLink {
            VaultSavedEntryDetailDestination(
              root: entry,
              childEntriesByParentID: childEntriesByParentID,
              isEditingDisabled: isEditingDisabled,
              isDeletingDisabled: isDeletingDisabled,
              transitionNamespace: transitionNamespace,
              onShare: onShare,
              onEdit: onEdit,
              onDelete: onDelete
            )
          } label: {
            VaultSavedEntryGridCell(content: entry.entryModel.content)
              .appMatchedTransitionSource(id: entry.edgeID, in: transitionNamespace)
          }
          .buttonStyle(.plain)
          .id(entry.edgeID)
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
            .disabled(isEditingDisabled || entry.kind == .file)

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
      "Delete Entry",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Entry", role: .destructive) {
        deleteCandidate = nil
        Task { @MainActor in
          _ = await onDelete(entry)
        }
      }
      Button("Cancel", role: .cancel) {
        deleteCandidate = nil
      }
    } message: { _ in
      Text(
        "This entry and its connected entries will be removed from this vault. Synced copies are deleted through iCloud."
      )
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

/// Lazily resolves the relationship-backed rows for an opened grid entry.
///
/// Keeping traversal behind the navigation destination prevents every lazy grid
/// cell from rebuilding its descendant list during ordinary layout. The visited
/// set also makes the display boundary safe while sync repair is resolving a
/// malformed parent cycle.
private struct VaultSavedEntryDetailDestination: View {

  let root: VaultSavedEntry
  let childEntriesByParentID: [UUID: [VaultSavedEntry]]
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool

  var body: some View {
    VaultSavedEntryDetailView(
      entries: subtreeEntries,
      rootTitle: root.kind.vaultListDisplayTitle,
      isEditingDisabled: isEditingDisabled,
      isDeletingDisabled: isDeletingDisabled,
      onShare: onShare,
      onEdit: onEdit,
      onDelete: onDelete
    )
    .appZoomNavigationTransition(
      sourceID: root.edgeID,
      in: transitionNamespace
    )
  }

  private var subtreeEntries: [VaultSavedEntry] {
    var result: [VaultSavedEntry] = []
    var visitedEdgeIDs: Set<UUID> = []

    func appendSubtree(startingAt entry: VaultSavedEntry) {
      guard visitedEdgeIDs.insert(entry.edgeID).inserted else {
        return
      }

      result.append(entry)
      for child in childEntriesByParentID[entry.edgeID] ?? [] {
        appendSubtree(startingAt: child)
      }
    }

    appendSubtree(startingAt: root)
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
      LazyVStack(alignment: .center, spacing: 40) {
        ForEach(entries) { entry in
          VaultSavedEntryDetailRow(
            entry: entry.entryModel,
            isEditingDisabled: isEditingDisabled || entry.kind == .file,
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
            .disabled(isEditingDisabled || entry.kind == .file)

            Button(role: .destructive) {
              deleteCandidate = entry
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .disabled(isDeletingDisabled)
          }
          .frame(maxWidth: detailMaximumContentWidth)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(detailScreenPadding)
    }
    .background(.background)
    .navigationTitle(rootTitle)
    .appInlineNavigationTitle()
    .confirmationDialog(
      "Delete Entry",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Entry", role: .destructive) {
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
      Text(
        "This entry and its connected entries will be removed from this vault. Synced copies are deleted through iCloud."
      )
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

extension VaultSavedEntry {

  /// Detached values handed to the share/export feature.
  ///
  /// The share sheet renders temporary files from this value copy, so it never
  /// holds a live SwiftData model or reaches back into the selected vault.
  fileprivate var shareSource: EntryShareSource {
    EntryShareSource(
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
  fileprivate var entryModel: VaultSavedEntryModel {
    VaultSavedEntryModel(
      id: edgeID,
      kind: kind,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      location: location,
      attachment: attachment?.entryModel
    )
  }
}

extension VaultSavedAttachment {

  fileprivate var shareSource: EntryShareAttachmentSource {
    EntryShareAttachmentSource(
      kind: kind,
      fileURL: fileURL,
      thumbnail: thumbnail,
      contentType: primaryResource?.contentType,
      byteSize: primaryResource?.byteSize
    )
  }

  fileprivate var entryModel: VaultSavedEntryAttachmentModel {
    VaultSavedEntryAttachmentModel(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: resources.first { $0.role == .pairedVideo }?.fileURL,
      fileRevision: fileRevision,
      thumbnail: thumbnail,
      pixelSize: primaryResource?.pixelSize,
      contentType: primaryResource?.contentType,
      byteSize: primaryResource?.byteSize,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }

  private var suggestionMediaFileURLsByResourceID: [UUID: URL] {
    resources.reduce(into: [UUID: URL]()) { result, resource in
      switch resource.role {
      case .suggestionImage, .suggestionVideo:
        result[resource.id] = resource.fileURL
      case .originalImage,
        .file,
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

extension Array where Element == VaultSavedEntry {

  fileprivate func sortedForVaultList() -> [VaultSavedEntry] {
    sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }

  fileprivate func sortedForVaultListSiblings() -> [VaultSavedEntry] {
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

extension UIImage {

  /// Pixel dimensions for persistence metadata derived from reloaded image data.
  fileprivate var pixelSize: CGSize {
    CGSize(width: size.width * scale, height: size.height * scale)
  }
}

#Preview("Saved Locations Map Header") {
  PrimaryContainer(accentColor: .default) {
    ScrollView {
      VaultSavedLocationsMapHeader(
        pins: VaultSavedLocationsMapPreviewFixtures.pins
      )
      .padding(cardSpacing)
    }
    .background(.background)
  }
}

#Preview("Saved Locations Map Overview") {
  PrimaryContainer(accentColor: .default) {
    NavigationStack {
      VaultSavedLocationsMapView(
        pins: VaultSavedLocationsMapPreviewFixtures.pins
      )
    }
  }
}

/// In-memory locations used only to validate map composition in Preview.
private enum VaultSavedLocationsMapPreviewFixtures {

  static let pins: [VaultSavedLocationPin] = [
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      coordinate: Coordinate(latitude: 35.6812, longitude: 139.7671),
      createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      coordinate: Coordinate(latitude: 35.6830, longitude: 139.7650),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_996_400)
    ),
    VaultSavedLocationPin(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      coordinate: Coordinate(latitude: 35.7148, longitude: 139.7745),
      createdAt: Date(timeIntervalSinceReferenceDate: 799_992_800)
    ),
  ]
}
