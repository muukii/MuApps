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

/// One continuation reveal owned by the detail route that created it.
///
/// Navigation keeps ancestor destinations alive. Carrying the local root with
/// the appended edge prevents a retained ancestor from consuming a descendant's
/// one-shot scroll request merely because both surfaces project that edge.
struct SavedListDetailScrollRequest: Equatable {
  let ownerDetailRootEdgeID: UUID
  let targetEdgeID: UUID

  func targetID(ownedBy detailRootEdgeID: UUID) -> UUID? {
    guard ownerDetailRootEdgeID == detailRootEdgeID else { return nil }
    return targetEdgeID
  }
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
  @Binding private var detailScrollRequest: SavedListDetailScrollRequest?
  @Binding private var selectedContentKind: JournalVault.Card.Kind?

  init(
    scrollTargetID: Binding<UUID?> = .constant(nil),
    navigationPath: Binding<[SavedListNavigationRoute]> = .constant([]),
    detailScrollRequest: Binding<SavedListDetailScrollRequest?> = .constant(nil),
    selectedContentKind: Binding<JournalVault.Card.Kind?> = .constant(nil)
  ) {
    _scrollTargetID = scrollTargetID
    _navigationPath = navigationPath
    _detailScrollRequest = detailScrollRequest
    _selectedContentKind = selectedContentKind
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
          detailScrollRequest: $detailScrollRequest,
          selectedContentKind: $selectedContentKind
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
  @Binding var detailScrollRequest: SavedListDetailScrollRequest?
  @Binding var selectedContentKind: JournalVault.Card.Kind?

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
  @State private var todoCompletionMutationCardIDs: Set<UUID> = []
  @State private var editErrorMessage: String?
  @State private var deleteErrorMessage: String?
  @State private var todoCompletionErrorMessage: String?
  @State private var deleteCandidate: VaultSavedEntry?
  @Namespace private var navigationTransitionNamespace

  init(
    vault: VaultInstance,
    scrollTargetID: Binding<UUID?>,
    navigationPath: Binding<[SavedListNavigationRoute]>,
    detailScrollRequest: Binding<SavedListDetailScrollRequest?>,
    selectedContentKind: Binding<JournalVault.Card.Kind?>
  ) {
    self.vault = vault
    _scrollTargetID = scrollTargetID
    _navigationPath = navigationPath
    _detailScrollRequest = detailScrollRequest
    _selectedContentKind = selectedContentKind
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
    let rootEntries = entries.filter { $0.parentEdgeID == nil }
    let rootEdgeIDs = Set(rootEntries.map(\.edgeID))
    let treeProjection = SavedEntryTreeProjection(
      entries: entries,
      parentID: { $0.parentEdgeID },
      areChildrenInIncreasingOrder: VaultSavedEntry.isOrderedBeforeSibling
    )
    let visibleRootEntries = Self.visibleRootEntries(
      from: rootEntries,
      selectedContentKind: selectedContentKind
    )
    let visibleEdgeIDs = Set(visibleRootEntries.map(\.edgeID))
    let isMutationDisabled =
      isEditDraftLoading || isSavingEdit || isDeletingEntry
      || todoCompletionMutationCardIDs.isEmpty == false
    let visibleSections = VaultSavedDaySection.sections(
      for: visibleRootEntries.sortedForVaultList(),
      calendar: calendar
    )
    let visibleTreesByRootID = visibleRootEntries.reduce(
      into: [UUID: SavedEntryTreeProjection<VaultSavedEntry>.Node]()
    ) { result, entry in
      guard let tree = treeProjection.tree(startingAt: entry.edgeID) else {
        return
      }
      result[entry.edgeID] = tree
    }
    let locationPins = Self.savedLocationPins(for: visibleRootEntries)

    ScrollViewReader { proxy in
      ScrollView {
        savedListContent(
          sections: visibleSections,
          treesByRootID: visibleTreesByRootID,
          locationPins: locationPins,
          isMutationDisabled: isMutationDisabled
        )
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
        resolvePendingRootScroll(
          using: proxy,
          rootEdgeIDs: rootEdgeIDs,
          visibleEdgeIDs: visibleEdgeIDs
        )
      }
      .onChange(of: rootEdgeIDs) { _, _ in
        resolvePendingRootScroll(
          using: proxy,
          rootEdgeIDs: rootEdgeIDs,
          visibleEdgeIDs: visibleEdgeIDs
        )
      }
      .onChange(of: visibleEdgeIDs) { _, _ in
        resolvePendingRootScroll(
          using: proxy,
          rootEdgeIDs: rootEdgeIDs,
          visibleEdgeIDs: visibleEdgeIDs
        )
      }
    }
    .frameAdaptive()
    .overlay {
      if visibleSections.isEmpty {
        VaultSavedListEmptyState(
          hasAnyRootEntries: rootEntries.isEmpty == false,
          selectedContentKind: selectedContentKind,
          onShowAllEntries: {
            selectedContentKind = nil
          }
        )
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .refreshable {
      await vaultRuntime.refresh()
    }
    .toolbar {
      ToolbarItem(placement: .appTrailingAction) {
        VaultSavedListContentFilterMenu(selection: $selectedContentKind)
      }
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
          treeProjection: treeProjection,
          navigationPath: $navigationPath,
          detailScrollRequest: $detailScrollRequest,
          isEditingDisabled: isMutationDisabled,
          isDeletingDisabled: isMutationDisabled,
          isTodoCompletionDisabled: isMutationDisabled,
          transitionNamespace: navigationTransitionNamespace,
          onShare: presentSharePreview,
          onEdit: presentEditDraft,
          onDelete: deleteEntry,
          onToggleTodoCompletion: toggleTodoCompletion
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
    .alert("Could Not Update Todo", isPresented: todoCompletionErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let todoCompletionErrorMessage {
        Text(todoCompletionErrorMessage)
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

  /// Builds the retained Home header and lazy entry stream in one boundary.
  ///
  /// The outer stack keeps the Map header alive while it is offscreen. One lazy
  /// stack still owns every entry row; nesting another `LazyVStack` per day
  /// would make the outer stack size a container that is itself still
  /// estimating its children. `Section` provides the day grouping without that
  /// unstable nested-lazy layout.
  private func savedListContent(
    sections: [VaultSavedDaySection],
    treesByRootID: [UUID: SavedEntryTreeProjection<VaultSavedEntry>.Node],
    locationPins: [VaultSavedLocationPin],
    isMutationDisabled: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if locationPins.isEmpty == false {
        VaultSavedLocationsMapNavigationHeader(
          pins: locationPins,
          transitionNamespace: navigationTransitionNamespace
        )
      }

      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(sections) { section in
          Section {
            ForEach(section.entries) { entry in
              VStack(alignment: .leading) {
                if let tree = treesByRootID[entry.edgeID] {
                  TreeDisplay(
                    root: tree,
                    spacing: VaultSavedEntryTreeMetrics.nodeSpacing
                  ) { entry, context in
                    VaultSavedEntryTreeCell(
                      depth: context.indentationDepth,
                      entry: entry,
                      isNavigationEnabled: true,
                      isMutationDisabled: isMutationDisabled,
                      transitionSourceTreeRootEdgeID: nil,
                      transitionNamespace: navigationTransitionNamespace,
                      onShare: presentSharePreview,
                      onEdit: presentEditDraft,
                      onRequestDelete: { entry in
                        deleteCandidate = entry
                      },
                      onToggleTodoCompletion: toggleTodoCompletion
                    )
                  }
                }
              }
            }
          } header: {
            VaultSavedDayHeader(day: section.day)
              .padding(.vertical, daySectionTopSpacing)
          }
        }
      }
    }
    .padding(.horizontal, savedListPadding)
  }

  private var entries: [VaultSavedEntry] {
    edges.compactMap { edge in
      guard let card = edge.card else { return nil }
      return VaultSavedEntry(edge: edge, card: card, store: vault.contentStore)
    }
  }

  /// Applies the Home-only content projection without changing the complete
  /// query snapshot used to construct entry-detail navigation.
  private static func visibleRootEntries(
    from rootEntries: [VaultSavedEntry],
    selectedContentKind: JournalVault.Card.Kind?
  ) -> [VaultSavedEntry] {
    guard let selectedContentKind else {
      return rootEntries
    }

    return rootEntries.filter { entry in
      entry.kind == selectedContentKind
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

  /// Resolves a root-post scroll after the edge reaches the live query.
  ///
  /// A visible root scrolls normally. A root hidden by the active filter clears
  /// the request without scrolling, so changing filters later cannot produce a
  /// stale jump. Unknown ids remain pending while persistence is still racing
  /// the query snapshot.
  private func resolvePendingRootScroll(
    using proxy: ScrollViewProxy,
    rootEdgeIDs: Set<UUID>,
    visibleEdgeIDs: Set<UUID>
  ) {
    guard let targetID = scrollTargetID, rootEdgeIDs.contains(targetID) else {
      return
    }

    if visibleEdgeIDs.contains(targetID) {
      withAnimation(.smooth) {
        proxy.scrollTo(targetID, anchor: .top)
      }
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

  private var todoCompletionErrorPresentation: Binding<Bool> {
    Binding {
      todoCompletionErrorMessage != nil
    } set: { isPresented in
      if isPresented == false {
        todoCompletionErrorMessage = nil
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

  /// Completes or reopens a Todo through the selected vault's transactional
  /// mutation boundary. SwiftData drives the visible row update; the explicit
  /// widget reload keeps the read-only latest-entry projection aligned.
  private func toggleTodoCompletion(_ entry: VaultSavedEntry) {
    guard entry.kind == .todo,
      todoCompletionMutationCardIDs.contains(entry.cardID) == false
    else {
      return
    }

    let shouldComplete = entry.isCompleted == false
    todoCompletionMutationCardIDs.insert(entry.cardID)

    Task { @MainActor in
      defer { todoCompletionMutationCardIDs.remove(entry.cardID) }

      do {
        guard let vault = vaultRuntime.selectedVault else {
          throw VaultSavedEntryEditDraftError.vaultUnavailable
        }

        let didChange = try vault.contentStore.setTodoCompletion(
          cardID: entry.cardID,
          isCompleted: shouldComplete
        )
        guard didChange else { return }

        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      } catch {
        todoCompletionErrorMessage = error.localizedDescription
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

/// Native single-selection menu for the content types that can appear on Home.
private struct VaultSavedListContentFilterMenu: View {

  @Binding var selection: JournalVault.Card.Kind?

  var body: some View {
    Menu {
      Picker("Filter Entries", selection: $selection) {
        Label("All Entries", systemImage: "square.stack.3d.up")
          .tag(JournalVault.Card.Kind?.none)

        ForEach(filterableKinds, id: \.self) { kind in
          Label {
            Text(kind.vaultListDisplayTitle)
          } icon: {
            Image(systemName: kind.vaultListSymbolName)
          }
          .tag(Optional(kind))
        }
      }
      .pickerStyle(.inline)
    } label: {
      Label("Filter Entries", systemImage: filterSymbolName)
        .labelStyle(.iconOnly)
    }
    .accessibilityLabel("Filter Entries")
    .accessibilityValue(accessibilityValue)
  }

  private var filterableKinds: [JournalVault.Card.Kind] {
    JournalVault.Card.Kind.allCases.filter(\.isAvailableInSavedListFilter)
  }

  private var filterSymbolName: String {
    selection == nil
      ? "line.3.horizontal.decrease.circle"
      : "line.3.horizontal.decrease.circle.fill"
  }

  private var accessibilityValue: Text {
    if let selection {
      Text(selection.vaultListDisplayTitle)
    } else {
      Text("All Entries")
    }
  }
}

/// Empty-state projection that distinguishes an empty vault from an empty
/// filter result while preserving an explicit path back to the complete list.
private struct VaultSavedListEmptyState: View {

  let hasAnyRootEntries: Bool
  let selectedContentKind: JournalVault.Card.Kind?
  let onShowAllEntries: @MainActor @Sendable () -> Void

  var body: some View {
    if hasAnyRootEntries, let selectedContentKind {
      ContentUnavailableView {
        Label(
          "No Matching Entries",
          systemImage: selectedContentKind.vaultListSymbolName
        )
      } description: {
        Text("This vault has no entries of the selected content type.")
      } actions: {
        Button("Show All Entries", action: onShowAllEntries)
      }
    } else {
      ContentUnavailableView("No Entries", systemImage: "book.closed")
        .allowsHitTesting(false)
    }
  }
}

extension JournalVault.Card.Kind {

  /// Whether users can intentionally author or import this type and therefore
  /// select it from Home's content filter.
  fileprivate var isAvailableInSavedListFilter: Bool {
    switch self {
    case .text, .todo, .link, .file, .photo, .video, .livePhoto, .audio,
      .suggestion, .doodle, .bauhaus:
      true
    case .unknown:
      false
    @unknown default:
      false
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
/// Extra lead-in above each day header in the saved-list stream.
private let daySectionTopSpacing: CGFloat = 16
