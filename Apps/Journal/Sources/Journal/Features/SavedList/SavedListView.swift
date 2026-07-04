import AVFoundation
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import JournalVault
import MuColor
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// Vault-backed entries list.
///
/// This screen intentionally reads only the selected `VaultInstance`. It does
/// not receive the legacy `JournalModel` container; legacy data enters the
/// current UI only after the sync layer has imported it into a vault store.
struct SavedListView: View {

  @Environment(\.calendar) private var calendar
  @Environment(\.appPalette) private var palette
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @State private var sections: [VaultSavedDaySection] = []
  @State private var childEntriesByParentID: [UUID: [VaultSavedEntrySnapshot]] = [:]
  @State private var isLoading = false
  @State private var loadErrorMessage: String?
  @State private var editPresentation: VaultSavedEntryEditPresentation?
  @State private var isEditDraftLoading = false
  @State private var isSavingEdit = false
  @State private var editErrorMessage: String?
  @Namespace private var navigationTransitionNamespace

  var body: some View {
    let columns = SavedListGrid.columns(for: horizontalSizeClass)

    ScrollView {
      LazyVStack(alignment: .leading, spacing: daySectionSpacing) {
        ForEach(sections) { section in
          VaultSavedDaySectionView(
            section: section,
            columns: columns,
            childEntriesByParentID: childEntriesByParentID,
            isEditingDisabled: isEditDraftLoading || isSavingEdit,
            transitionNamespace: navigationTransitionNamespace,
            onEdit: presentEditDraft
          )
        }
      }
      .padding(cardSpacing)
    }
    .overlay {
      if isLoading {
        ProgressView()
      } else if vaultRuntime.selectedVaultState != .active {
        ContentUnavailableView("Vault Not Ready", systemImage: "externaldrive")
      } else if sections.isEmpty {
        ContentUnavailableView("No Cards", systemImage: "book.closed")
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle(vaultRuntime.selectedVault?.title ?? "Entries")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          loadEntries()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
        .accessibilityLabel("Reload Entries")
      }
    }
    .refreshable {
      loadEntries()
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
    .alert("Could Not Load Entries", isPresented: loadErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let loadErrorMessage {
        Text(loadErrorMessage)
      }
    }
    .alert("Could Not Edit Card", isPresented: editErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let editErrorMessage {
        Text(editErrorMessage)
      }
    }
    .task(id: vaultRuntime.selectedVault?.vaultID.rawValue) {
      loadEntries()
    }
    .onReceive(NotificationCenter.default.publisher(for: VaultMediaFileChange.name)) { notification in
      guard shouldReload(for: notification) else { return }
      loadEntries()
    }
  }

  private var loadErrorPresentation: Binding<Bool> {
    Binding {
      loadErrorMessage != nil
    } set: { isPresented in
      if isPresented == false {
        loadErrorMessage = nil
      }
    }
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

  private func loadEntries() {
    guard let vault = vaultRuntime.selectedVault else {
      sections = []
      childEntriesByParentID = [:]
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      let reader = VaultSavedEntryReader(store: vault.contentStore, calendar: calendar)
      let snapshot = try reader.snapshot()
      sections = snapshot.sections
      childEntriesByParentID = snapshot.childEntriesByParentID
      loadErrorMessage = nil
    } catch {
      sections = []
      childEntriesByParentID = [:]
      loadErrorMessage = error.localizedDescription
    }
  }

  private func shouldReload(for notification: Notification) -> Bool {
    guard let vaultID = notification.userInfo?[VaultMediaFileChange.vaultIDKey] as? VaultID else {
      return false
    }
    return vaultID == vaultRuntime.selectedVault?.vaultID
  }

  private func presentEditDraft(for entry: VaultSavedEntrySnapshot) {
    guard isEditDraftLoading == false, isSavingEdit == false else {
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

        let draft = try presentation.draft.savingSnapshot().vaultDraft(
          palette: palette,
          colorScheme: colorScheme
        )
        try vault.contentStore.updateCard(cardID: presentation.cardID, with: draft)
        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
        editPresentation = nil
        loadEntries()
      } catch {
        editErrorMessage = error.localizedDescription
      }
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

// MARK: - Reading

private struct VaultSavedEntryReader {

  let store: VaultContentStore
  let calendar: Calendar

  @MainActor
  func snapshot() throws -> VaultSavedListSnapshot {
    let context = store.container.mainContext
    let cards = try context.fetch(
      FetchDescriptor<JournalVault.Card>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
    )
    let edges = try context.fetch(
      FetchDescriptor<JournalVault.CardEdge>(
        sortBy: [
          SortDescriptor(\.createdAt, order: .reverse),
          SortDescriptor(\.sortIndex),
        ]
      )
    )
    let attachments = try context.fetch(
      FetchDescriptor<JournalVault.Attachment>(
        sortBy: [SortDescriptor(\.createdAt)]
      )
    )

    let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    let edgeIDs = Set(edges.map(\.id))
    let attachmentByCardID = attachments.reduce(into: [UUID: JournalVault.Attachment]()) { result, attachment in
      if result[attachment.cardID] == nil {
        result[attachment.cardID] = attachment
      }
    }

    let entries = edges.compactMap { edge -> VaultSavedEntrySnapshot? in
      guard let card = cardsByID[edge.cardID] else { return nil }
      return VaultSavedEntrySnapshot(
        edgeID: edge.id,
        cardID: card.id,
        parentEdgeID: edge.parentEdgeID,
        sortIndex: edge.sortIndex,
        kind: card.kind,
        body: card.body,
        createdAt: card.createdAt,
        updatedAt: card.updatedAt,
        location: card.location,
        attachment: attachmentByCardID[card.id].map { attachment in
          VaultSavedAttachmentSnapshot(
            id: attachment.id,
            kind: attachment.kind,
            byteSize: attachment.byteSize,
            thumbnail: attachment.thumbnail,
            fileURL: store.fileURL(for: attachment)
          )
        }
      )
    }

    let childEntriesByParentID = entries
      .filter { entry in
        entry.parentEdgeID.map(edgeIDs.contains) ?? false
      }
      .reduce(into: [UUID: [VaultSavedEntrySnapshot]]()) { result, entry in
        guard let parentEdgeID = entry.parentEdgeID else { return }
        result[parentEdgeID, default: []].append(entry)
      }
      .mapValues { $0.sortedForVaultListSiblings() }

    let rootEntries = entries
      .filter { entry in
        entry.parentEdgeID.map(edgeIDs.contains) != true
      }
      .sortedForVaultList()
    let sections = VaultSavedDaySection.sections(for: rootEntries, calendar: calendar)

    return VaultSavedListSnapshot(
      sections: sections,
      childEntriesByParentID: childEntriesByParentID
    )
  }
}

private struct VaultSavedListSnapshot {
  var sections: [VaultSavedDaySection]
  var childEntriesByParentID: [UUID: [VaultSavedEntrySnapshot]]
}

/// Value snapshot used by the list and detail UI.
///
/// The live SwiftData models stay behind `VaultSavedEntryReader`; views render
/// stable value snapshots and explicitly reload when the selected vault or media
/// file availability changes.
private struct VaultSavedEntrySnapshot: Identifiable, Hashable {
  var id: UUID { edgeID }

  let edgeID: UUID
  let cardID: UUID
  let parentEdgeID: UUID?
  let sortIndex: Int
  let kind: JournalVault.Card.Kind
  let body: String
  let createdAt: Date
  let updatedAt: Date
  let location: JournalVault.Coordinate?
  let attachment: VaultSavedAttachmentSnapshot?
}

extension VaultSavedEntrySnapshot {

  /// Rehydrates this saved card into the shared editing draft model.
  ///
  /// Media cards require the full vault media file. Thumbnails are display-only
  /// fallbacks and are intentionally not used to create a lossy edit draft.
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
    case .audio:
      let fileURL = try mediaFileURL(matching: .audio)
      let editableURL = try VaultSavedEntryEditMediaPreparer.audioCopy(from: fileURL)
      return CardEditDraft(
        kind: .audio,
        audio: AudioRecording(
          fileURL: editableURL,
          duration: VaultSavedEntryEditMediaPreparer.audioDuration(from: editableURL)
        ),
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

  private func mediaData(matching kind: JournalVault.Attachment.Kind) async throws -> Data {
    let fileURL = try mediaFileURL(matching: kind)
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }
}

private struct VaultSavedAttachmentSnapshot: Hashable {
  let id: UUID
  let kind: JournalVault.Attachment.Kind
  let byteSize: Int
  let thumbnail: Data?
  let fileURL: URL
}

/// Errors surfaced when a saved vault entry cannot be reopened as an editable draft.
private enum VaultSavedEntryEditDraftError: LocalizedError {
  case vaultUnavailable
  case mediaUnavailable
  case mediaDecodeFailed
  case audioCopyFailed
  case unsupportedKind

  var errorDescription: String? {
    switch self {
    case .vaultUnavailable:
      return "The selected vault is not available."
    case .mediaUnavailable:
      return "This card's media file is not available on this device yet."
    case .mediaDecodeFailed:
      return "This card's media file could not be read for editing."
    case .audioCopyFailed:
      return "This audio recording could not be prepared for editing."
    case .unsupportedKind:
      return "This card type is not editable yet."
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
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }

    let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("journal-vault-edit-audio-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)

    do {
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    } catch {
      throw VaultSavedEntryEditDraftError.audioCopyFailed
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
  var entries: [VaultSavedEntrySnapshot]

  static func sections(
    for entries: [VaultSavedEntrySnapshot],
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
  let childEntriesByParentID: [UUID: [VaultSavedEntrySnapshot]]
  let isEditingDisabled: Bool
  let transitionNamespace: Namespace.ID
  let onEdit: @MainActor (VaultSavedEntrySnapshot) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: dayHeaderSpacing) {
      VaultSavedDayHeader(day: section.day)

      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(section.entries) { entry in
          NavigationLink {
            VaultSavedEntryDetailView(
              entries: subtreeEntries(startingAt: entry),
              rootTitle: entry.kind.vaultListDisplayTitle,
              isEditingDisabled: isEditingDisabled,
              onEdit: onEdit
            )
            .navigationTransition(.zoom(sourceID: entry.edgeID, in: transitionNamespace))
          } label: {
            VaultSavedEntryTile(
              entry: entry,
              childCount: subtreeEntries(startingAt: entry).count - 1
            )
            .matchedTransitionSource(id: entry.edgeID, in: transitionNamespace)
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button {
              onEdit(entry)
            } label: {
              Label("Edit", systemImage: "square.and.pencil")
            }
            .disabled(isEditingDisabled)
          }
        }
      }
    }
  }

  private func subtreeEntries(startingAt root: VaultSavedEntrySnapshot) -> [VaultSavedEntrySnapshot] {
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

private struct VaultSavedEntryTile: View {

  let entry: VaultSavedEntrySnapshot
  let childCount: Int

  var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: entry.kind.vaultListSymbolName)
          Text(entry.kind.vaultListDisplayTitle)
          Spacer(minLength: 0)
          if childCount > 0 {
            Label {
              Text(childCount + 1, format: .number)
            } icon: {
              Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("\(childCount + 1) cards")
          }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.70))

        VaultSavedEntryPreviewContent(entry: entry, isDetail: false)

        Spacer(minLength: 0)

        Text(entry.createdAt, format: .dateTime.hour().minute())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
      }
    }
  }
}

private struct VaultSavedEntryDetailView: View {

  let entries: [VaultSavedEntrySnapshot]
  let rootTitle: LocalizedStringResource
  let isEditingDisabled: Bool
  let onEdit: @MainActor (VaultSavedEntrySnapshot) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .center, spacing: 24) {
        ForEach(entries) { entry in
          VaultSavedEntryDetailCard(
            entry: entry,
            isEditingDisabled: isEditingDisabled,
            onEdit: onEdit
          )
          .frame(maxWidth: detailMaximumCardWidth)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(detailScreenPadding)
    }
    .background(.background)
    .navigationTitle(rootTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct VaultSavedEntryDetailCard: View {

  let entry: VaultSavedEntrySnapshot
  let isEditingDisabled: Bool
  let onEdit: @MainActor (VaultSavedEntrySnapshot) -> Void

  var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Image(systemName: entry.kind.vaultListSymbolName)
          Text(entry.kind.vaultListDisplayTitle)
          Spacer(minLength: 0)
          Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
          Button {
            onEdit(entry)
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .buttonStyle(.plain)
          .disabled(isEditingDisabled)
          .accessibilityLabel("Edit Card")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.70))

        VaultSavedEntryPreviewContent(entry: entry, isDetail: true)

        Spacer(minLength: 0)

        VaultSavedEntryMetadata(entry: entry)
      }
    }
  }
}

private struct VaultSavedEntryPreviewContent: View {

  let entry: VaultSavedEntrySnapshot
  let isDetail: Bool

  var body: some View {
    switch entry.kind {
    case .text:
      Text(entry.body.isEmpty ? "Empty text card" : entry.body)
        .font(isDetail ? .title3.weight(.semibold) : .headline.weight(.semibold))
        .lineLimit(isDetail ? nil : 8)
    case .link:
      VaultSavedLinkPreview(urlString: entry.body, isDetail: isDetail)
    case .photo:
      VaultSavedMediaPreview(
        attachment: entry.attachment,
        fallbackSystemImage: "photo",
        isDetail: isDetail
      )
    case .audio:
      VaultSavedAudioPreview(isDetail: isDetail)
    case .doodle:
      VaultSavedMediaPreview(
        attachment: entry.attachment,
        fallbackSystemImage: "scribble",
        isDetail: isDetail
      )
    case .bauhaus:
      VaultSavedMediaPreview(
        attachment: entry.attachment,
        fallbackSystemImage: "square.grid.3x3",
        isDetail: isDetail
      )
    case .unknown:
      VaultSavedUnknownPreview()
    @unknown default:
      VaultSavedUnknownPreview()
    }
  }
}

private struct VaultSavedLinkPreview: View {

  let urlString: String
  let isDetail: Bool

  var body: some View {
    if let linkURL = JournalLinkURL(urlString) {
      JournalLinkPreview(
        url: linkURL.url,
        mode: isDetail ? .detail : .summary
      )
    } else {
      Text(urlString.isEmpty ? "Empty link card" : urlString)
        .font(isDetail ? .title3.weight(.semibold) : .headline.weight(.semibold))
        .lineLimit(isDetail ? nil : 8)
    }
  }
}

private struct VaultSavedMediaPreview: View {

  let attachment: VaultSavedAttachmentSnapshot?
  let fallbackSystemImage: String
  let isDetail: Bool

  var body: some View {
    if let image = image {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .aspectRatio(isDetail ? 4 / 3 : 1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    } else {
      VaultSavedMediaPlaceholder(systemImage: fallbackSystemImage)
        .aspectRatio(isDetail ? 4 / 3 : 1, contentMode: .fit)
    }
  }

  private var image: UIImage? {
    if let fileURL = attachment?.fileURL,
       FileManager.default.fileExists(atPath: fileURL.path),
       let image = UIImage(contentsOfFile: fileURL.path) {
      return image
    }

    if let thumbnail = attachment?.thumbnail {
      return UIImage(data: thumbnail)
    }

    return nil
  }
}

private struct VaultSavedAudioPreview: View {

  let isDetail: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Audio", systemImage: "waveform")
        .font(.headline.weight(.semibold))

      HStack(alignment: .center, spacing: 4) {
        ForEach(VaultSavedAudioWaveformSample.samples) { sample in
          Capsule()
            .fill(.appOnSecondaryContainer.opacity(0.62))
            .frame(width: 4, height: sample.height)
        }
      }
      .frame(maxWidth: .infinity, minHeight: isDetail ? 96 : 52, alignment: .center)
    }
  }
}

private struct VaultSavedAudioWaveformSample: Identifiable {
  let id = UUID()
  let height: CGFloat

  static let samples: [VaultSavedAudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44, 64, 50, 36, 22,
  ].map { VaultSavedAudioWaveformSample(height: CGFloat($0)) }
}

private struct VaultSavedMediaPlaceholder: View {

  let systemImage: String

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(.appOnSecondaryContainer.opacity(0.08))
      .overlay {
        Image(systemName: systemImage)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      }
  }
}

private struct VaultSavedUnknownPreview: View {

  var body: some View {
    VaultSavedMediaPlaceholder(systemImage: "questionmark.square.dashed")
  }
}

private struct VaultSavedEntryMetadata: View {

  let entry: VaultSavedEntrySnapshot

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

// MARK: - Sorting

private extension Array where Element == VaultSavedEntrySnapshot {

  func sortedForVaultList() -> [VaultSavedEntrySnapshot] {
    sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }

  func sortedForVaultListSiblings() -> [VaultSavedEntrySnapshot] {
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

private extension JournalVault.Card.Kind {

  var vaultListDisplayTitle: LocalizedStringResource {
    switch self {
    case .text:
      "Text"
    case .link:
      "Link"
    case .photo:
      "Photo"
    case .audio:
      "Audio"
    case .doodle:
      "Doodle"
    case .bauhaus:
      "Bauhaus"
    case .unknown:
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
    case .audio:
      "waveform"
    case .doodle:
      "scribble"
    case .bauhaus:
      "square.grid.3x3"
    case .unknown:
      "questionmark.square.dashed"
    }
  }
}
