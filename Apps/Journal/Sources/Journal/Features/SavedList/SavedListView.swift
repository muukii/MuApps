import AppUIComponents
import JournalVault
import MuColor
import SwiftData
import SwiftUI
import WidgetKit

/// Value-based destinations owned by Journal's root navigation stack.
///
/// Entry routes carry only a stable placement id. Every pushed level resolves
/// the current SwiftData snapshot again, which lets the same destination render
/// a root, child, or deeper descendant without a second navigation model.
enum SavedListNavigationRoute: Hashable {
  case locations
  case entry(edgeID: UUID)
}

/// Vault-backed entries list.
///
/// This screen intentionally reads only the selected `VaultInstance`. It does
/// not receive any legacy persistence container; legacy data enters the current
/// UI only after the sync layer has imported it into a vault store.
struct SavedListView: View {

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @Binding private var scrollTargetID: UUID?
  @Binding private var navigationPath: [SavedListNavigationRoute]
  @Binding private var detailScrollTargetID: UUID?

  init(
    scrollTargetID: Binding<UUID?> = .constant(nil),
    navigationPath: Binding<[SavedListNavigationRoute]> = .constant([]),
    detailScrollTargetID: Binding<UUID?> = .constant(nil)
  ) {
    _scrollTargetID = scrollTargetID
    _navigationPath = navigationPath
    _detailScrollTargetID = detailScrollTargetID
  }

  var body: some View {
    Group {
      if let vault = vaultRuntime.selectedVault,
        vaultRuntime.selectedVaultState == .active
      {
        VaultSavedListContentView(
          vault: vault,
          scrollTargetID: $scrollTargetID,
          navigationPath: $navigationPath,
          detailScrollTargetID: $detailScrollTargetID
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
  @Binding var navigationPath: [SavedListNavigationRoute]
  @Binding var detailScrollTargetID: UUID?

  @Environment(\.calendar) private var calendar
  @Environment(\.appPalette) private var palette
  @Environment(\.composerOverlayHeight) private var composerOverlayHeight
  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @Query
  private var edges: [JournalVault.CardEdge]

  @State private var sharePreviewPresentation: EntrySharePreviewPresentation?
  @State private var editPresentation: VaultSavedEntryEditPresentation?
  @State private var isEditDraftLoading = false
  @State private var isSavingEdit = false
  @State private var isDeletingEntry = false
  @State private var editErrorMessage: String?
  @State private var deleteErrorMessage: String?
  @State private var deleteCandidate: VaultSavedEntry?
  @Namespace private var navigationTransitionNamespace

  init(
    vault: VaultInstance,
    scrollTargetID: Binding<UUID?>,
    navigationPath: Binding<[SavedListNavigationRoute]>,
    detailScrollTargetID: Binding<UUID?>
  ) {
    self.vault = vault
    _scrollTargetID = scrollTargetID
    _navigationPath = navigationPath
    _detailScrollTargetID = detailScrollTargetID
    _edges = Query(
      filter: #Predicate<JournalVault.CardEdge> { edge in
        edge.deletedAt == nil
      },
      sort: [
        SortDescriptor(\JournalVault.CardEdge.createdAt, order: .reverse),
        SortDescriptor(\JournalVault.CardEdge.sortIndex),
      ]
    )
  }

  var body: some View {
    let entries = entries
    let edgeIDs = Set(entries.map(\.edgeID))
    let rootEntries = entries.filter { $0.parentEdgeID == nil }
    let visibleEdgeIDs = Set(rootEntries.map(\.edgeID))
    let isMutationDisabled =
      isEditDraftLoading || isSavingEdit || isDeletingEntry
    let visibleSections = VaultSavedDaySection.sections(
      for: rootEntries.sortedForVaultList(),
      calendar: calendar
    )
    let childEntriesByParentID = Self.childEntriesByParentID(
      for: entries,
      edgeIDs: edgeIDs
    )
    let locationPins = Self.savedLocationPins(for: rootEntries)

    ScrollViewReader { proxy in
      ScrollView {
        // One lazy stack owns every row. Nesting a second `LazyVStack` per day
        // would force the outer stack to size a container that is itself still
        // estimating its children, which drifts the content height while
        // scrolling. `Section` gives the same day grouping inside one stack.
        LazyVStack(alignment: .leading, spacing: 2) {
          if locationPins.isEmpty == false {
            VaultSavedLocationsMapNavigationHeader(
              pins: locationPins,
              transitionNamespace: navigationTransitionNamespace
            )
          }

          ForEach(visibleSections) { section in
            Section {
              ForEach(section.entries) { entry in
                VaultSavedEntryRow(
                  entry: entry,
                  isMutationDisabled: isMutationDisabled,
                  transitionNamespace: navigationTransitionNamespace,
                  onShare: presentSharePreview,
                  onEdit: presentEditDraft,
                  onRequestDelete: { entry in
                    deleteCandidate = entry
                  }
                )
              }
            } header: {
              VaultSavedDayHeader(day: section.day)
                .padding(.vertical, daySectionTopSpacing)
            }
          }
        }
        .padding(.horizontal, 16)
      }
      .contentMargins(
        .bottom,
        composerOverlayHeight,
        for: .scrollContent
      )
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .scrollDismissesKeyboard(.interactively)
      .scrollBounceBehavior(.always, axes: .vertical)
      .onChange(of: scrollTargetID, initial: true) { _, _ in
        scrollToPendingEntry(using: proxy, availableEdgeIDs: visibleEdgeIDs)
      }
      .onChange(of: visibleEdgeIDs) { _, _ in
        scrollToPendingEntry(using: proxy, availableEdgeIDs: visibleEdgeIDs)
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
    .navigationDestination(for: SavedListNavigationRoute.self) { route in
      switch route {
      case .locations:
        VaultSavedLocationsMapView(pins: locationPins)
          .appZoomNavigationTransition(
            sourceID: VaultSavedLocationsMapTransition.id,
            in: navigationTransitionNamespace
          )
      case .entry(let edgeID):
        VaultSavedEntryDetailDestination(
          edgeID: edgeID,
          entries: entries,
          childEntriesByParentID: childEntriesByParentID,
          navigationPath: $navigationPath,
          detailScrollTargetID: $detailScrollTargetID,
          isEditingDisabled: isMutationDisabled,
          isDeletingDisabled: isMutationDisabled,
          transitionNamespace: navigationTransitionNamespace,
          onShare: presentSharePreview,
          onEdit: presentEditDraft,
          onDelete: deleteEntry
        )
      }
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
    .confirmationDialog(
      "Delete Entry",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Entry", role: .destructive) {
        deleteCandidate = nil
        Task { @MainActor in
          _ = await deleteEntry(entry)
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
    guard let targetID = scrollTargetID, availableEdgeIDs.contains(targetID)
    else {
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
    guard isEditDraftLoading == false, isSavingEdit == false,
      isDeletingEntry == false
    else {
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
        try vault.contentStore.updateCard(
          cardID: presentation.cardID,
          with: draft
        )
        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(
          ofKind: JournalWidgetKind.latestNote
        )
        editPresentation = nil
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }

  @MainActor
  private func deleteEntry(_ entry: VaultSavedEntry) async -> Bool {
    guard isDeletingEntry == false, isEditDraftLoading == false,
      isSavingEdit == false
    else {
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

// MARK: - Layout

private let savedListPadding: CGFloat = 16
/// Gap between every row of the single saved-list stack.
private let entrySpacing: CGFloat = 12
/// Extra lead-in above a day header, on top of `entrySpacing`.
private let daySectionTopSpacing: CGFloat = 16
