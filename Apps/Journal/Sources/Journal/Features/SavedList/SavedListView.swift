import AppUIComponents
import JournalVault
import MuColor
import SwiftData
import SwiftUI
import WidgetKit

/// Value-based destinations retained outside Home's tree interaction.
enum SavedListNavigationRoute: Hashable {
  case locations
}

/// Stable identifiers retained while the destructive confirmation is visible.
///
/// The dialog deliberately does not keep SwiftData models alive after the row's
/// context menu closes. The selected vault resolves the mutation from these IDs.
private struct VaultSavedEntryDeleteCandidate {
  let edgeID: UUID
  let cardID: UUID
}

/// Vault-backed entries list.
///
/// This screen intentionally reads only the selected `VaultInstance`. It does
/// not receive any legacy persistence container; legacy data enters the current
/// UI only after the sync layer has imported it into a vault store.
struct SavedListView: View {

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @Binding private var selectedContentKind: JournalVault.Card.Kind?
  private let replyTarget: SavedListReplyTarget?
  @Binding private var scrollRequest: SavedListScrollRequest?
  private let onSelectReplyTarget: @MainActor (SavedListReplyTarget) -> Void
  private let onReplyTargetAvailabilityChange: @MainActor (Bool) -> Void

  init(
    selectedContentKind: Binding<JournalVault.Card.Kind?> = .constant(nil),
    replyTarget: SavedListReplyTarget? = nil,
    scrollRequest: Binding<SavedListScrollRequest?> = .constant(nil),
    onSelectReplyTarget: @escaping @MainActor (SavedListReplyTarget) -> Void = {
      _ in
    },
    onReplyTargetAvailabilityChange: @escaping @MainActor (Bool) -> Void = {
      _ in
    }
  ) {
    _selectedContentKind = selectedContentKind
    self.replyTarget = replyTarget
    _scrollRequest = scrollRequest
    self.onSelectReplyTarget = onSelectReplyTarget
    self.onReplyTargetAvailabilityChange = onReplyTargetAvailabilityChange
  }

  var body: some View {
    Group {
      if let vault = vaultRuntime.selectedVault,
        vaultRuntime.selectedVaultState == .active
      {
        VaultSavedListContentView(
          vault: vault,
          selectedContentKind: $selectedContentKind,
          replyTarget: replyTarget,
          scrollRequest: $scrollRequest,
          onSelectReplyTarget: onSelectReplyTarget,
          onReplyTargetAvailabilityChange: onReplyTargetAvailabilityChange
        )
        .modelContainer(vault.contentStore.container)
      } else {
        ContentUnavailableView("Vault Not Ready", systemImage: "externaldrive")
          .onChange(of: replyTarget, initial: true) { _, replyTarget in
            // Removing the live query surface must invalidate a retained Reply
            // immediately. The target stays visible, but cannot post until an
            // active query validates the placement again.
            onReplyTargetAvailabilityChange(replyTarget == nil)
          }
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

  @Binding var selectedContentKind: JournalVault.Card.Kind?
  let replyTarget: SavedListReplyTarget?
  @Binding var scrollRequest: SavedListScrollRequest?
  let onSelectReplyTarget: @MainActor (SavedListReplyTarget) -> Void
  let onReplyTargetAvailabilityChange: @MainActor (Bool) -> Void

  @Environment(\.appPalette) private var palette
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
  @State private var deleteCandidate: VaultSavedEntryDeleteCandidate?

  init(
    vault: VaultInstance,
    selectedContentKind: Binding<JournalVault.Card.Kind?>,
    replyTarget: SavedListReplyTarget?,
    scrollRequest: Binding<SavedListScrollRequest?>,
    onSelectReplyTarget: @escaping @MainActor (SavedListReplyTarget) -> Void,
    onReplyTargetAvailabilityChange: @escaping @MainActor (Bool) -> Void
  ) {
    self.vault = vault
    _selectedContentKind = selectedContentKind
    self.replyTarget = replyTarget
    _scrollRequest = scrollRequest
    self.onSelectReplyTarget = onSelectReplyTarget
    self.onReplyTargetAvailabilityChange = onReplyTargetAvailabilityChange
    _edges = Query(
      filter: #Predicate<JournalVault.CardEdge> { edge in
        edge.deletedAt == nil
      },
      sort: [
        SortDescriptor(\JournalVault.CardEdge.createdAt, order: .reverse),
        SortDescriptor(\JournalVault.CardEdge.sortIndex),
      ],
      animation: .smooth
    )
  }

  var body: some View {
    VaultSavedListTreeSurface(
      vault: vault,
      edges: edges,
      selectedContentKind: $selectedContentKind,
      replyTarget: replyTarget,
      scrollRequest: $scrollRequest,
      onSelectReplyTarget: selectReplyTarget,
      onShare: presentSharePreview,
      onEdit: presentEditDraft,
      onRequestDelete: { edge, card in
        deleteCandidate = VaultSavedEntryDeleteCandidate(
          edgeID: edge.id,
          cardID: card.id
        )
      },
      onToggleTodoCompletion: toggleTodoCompletion,
      onReplyTargetAvailabilityChange: onReplyTargetAvailabilityChange
    )
    .environment(
      \.savedListMutationDisabled,
      isEditDraftLoading || isSavingEdit || isDeletingEntry
        || todoCompletionMutationCardIDs.isEmpty == false
    )
    .frameAdaptive()
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
    .alert(
      "Could Not Update Todo",
      isPresented: todoCompletionErrorPresentation
    ) {
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
          await deleteEntry(entry)
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

  /// Detaches the placement selected by a context-menu Reply action from the
  /// live SwiftData models before lifting it to composer state.
  private func selectReplyTarget(
    edge: JournalVault.CardEdge,
    card: JournalVault.Card,
    ownerRootEdgeID: UUID
  ) {
    onSelectReplyTarget(
      SavedListReplyTarget(
        vaultID: vault.vaultID,
        parentEdgeID: edge.id,
        ownerRootEdgeID: ownerRootEdgeID,
        displaySummary: card.replyDisplaySummary
      )
    )
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

  private func presentEditDraft(for card: JournalVault.Card) {
    guard isEditDraftLoading == false, isSavingEdit == false,
      isDeletingEntry == false
    else {
      return
    }

    isEditDraftLoading = true
    let cardID = card.id
    let contentStore = vault.contentStore

    Task { @MainActor in
      defer { isEditDraftLoading = false }

      do {
        editPresentation = VaultSavedEntryEditPresentation(
          cardID: cardID,
          draft: try await card.editDraft(store: contentStore)
        )
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }

  private func presentSharePreview(
    edge: JournalVault.CardEdge,
    card: JournalVault.Card
  ) {
    sharePreviewPresentation = EntrySharePreviewPresentation(
      snapshot: EntryShareSnapshot(
        source: card.shareSource(
          edgeID: edge.id,
          store: vault.contentStore
        )
      ),
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
  private func toggleTodoCompletion(_ card: JournalVault.Card) {
    let cardID = card.id
    guard card.kind == .todo,
      todoCompletionMutationCardIDs.contains(cardID) == false
    else {
      return
    }

    let shouldComplete = card.isCompleted == false
    todoCompletionMutationCardIDs.insert(cardID)

    Task { @MainActor in
      defer { todoCompletionMutationCardIDs.remove(cardID) }

      do {
        guard let vault = vaultRuntime.selectedVault else {
          throw VaultSavedEntryEditDraftError.vaultUnavailable
        }

        let didChange = try vault.contentStore.setTodoCompletion(
          cardID: cardID,
          isCompleted: shouldComplete
        )
        guard didChange else { return }

        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(
          ofKind: JournalWidgetKind.latestNote
        )
      } catch {
        todoCompletionErrorMessage = error.localizedDescription
      }
    }
  }

  @MainActor
  private func deleteEntry(_ candidate: VaultSavedEntryDeleteCandidate) async {
    guard isDeletingEntry == false, isEditDraftLoading == false,
      isSavingEdit == false
    else {
      return
    }

    isDeletingEntry = true
    defer { isDeletingEntry = false }

    do {
      guard let vault = vaultRuntime.selectedVault else {
        throw VaultSavedEntryEditDraftError.vaultUnavailable
      }

      // Live tree rows observe `deletedAt` directly, so they can disappear
      // before `@Query` publishes its animated result change. Animate the
      // synchronous main-context mutation itself as well.
      try withAnimation(.smooth) {
        try vault.contentStore.deleteCardEdge(edgeID: candidate.edgeID)
      }
      if editPresentation?.cardID == candidate.cardID {
        editPresentation = nil
      }
      await vaultRuntime.refresh()
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
    } catch {
      deleteErrorMessage = error.localizedDescription
    }
  }
}

/// Owns Home's live tree traversal boundary.
///
/// The parent screen owns presentations and mutations. This surface owns only
/// the query-backed list structure, so changing an edit or delete presentation
/// does not require the parent `body` to rebuild a detached content tree.
private struct VaultSavedListTreeSurface: View {

  let vault: VaultInstance
  let edges: [JournalVault.CardEdge]
  @Binding var selectedContentKind: JournalVault.Card.Kind?
  let replyTarget: SavedListReplyTarget?
  @Binding var scrollRequest: SavedListScrollRequest?
  let onSelectReplyTarget: @MainActor (JournalVault.CardEdge, JournalVault.Card, UUID) -> Void
  let onShare: @MainActor (JournalVault.CardEdge, JournalVault.Card) -> Void
  let onEdit: @MainActor (JournalVault.Card) -> Void
  let onRequestDelete: @MainActor (JournalVault.CardEdge, JournalVault.Card) -> Void
  let onToggleTodoCompletion: @MainActor (JournalVault.Card) -> Void
  let onReplyTargetAvailabilityChange: @MainActor (Bool) -> Void

  @Environment(\.calendar) private var calendar
  @Environment(\.composerOverlayHeight) private var composerOverlayHeight
  @Namespace private var navigationTransitionNamespace

  var body: some View {
    let rootEdges = VaultSavedListTreeTraversal.activeResolvedRoots(from: edges)
    let visibleRootEdges = VaultSavedListTreeTraversal.visibleRoots(
      from: rootEdges,
      selectedContentKind: selectedContentKind
    )
    let visibleSections = VaultSavedDaySection.sections(
      for: visibleRootEdges,
      calendar: calendar
    )
    let allEdgeIDs = VaultSavedListTreeTraversal.activeResolvedEdgeIDs(
      from: edges
    )
    let visibleRootEdgeIDs = Set(visibleRootEdges.map(\.id))
    let locationPins = Self.savedLocationPins(
      for: VaultSavedListTreeTraversal.visiblePlacements(
        in: visibleRootEdges,
        selectedContentKind: selectedContentKind
      )
    )

    ScrollViewReader { proxy in
      ScrollView {
        savedListContent(
          sections: visibleSections,
          locationPins: locationPins
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
      .overlayPreferenceValue(SavedListRenderedEdgeIDsPreferenceKey.self) {
        renderedEdgeIDs in
        SavedListScrollCoordinator(
          request: $scrollRequest,
          allEdgeIDs: allEdgeIDs,
          rootEdges: rootEdges,
          visibleRootEdgeIDs: visibleRootEdgeIDs,
          selectedContentKind: selectedContentKind,
          renderedEdgeIDs: renderedEdgeIDs,
          proxy: proxy
        )
      }
    }
    .overlay {
      if visibleSections.isEmpty {
        VaultSavedListEmptyState(
          hasAnyRootEntries: rootEdges.isEmpty == false,
          selectedContentKind: selectedContentKind,
          onShowAllEntries: {
            selectedContentKind = nil
          }
        )
      }
    }
    .background {
      SavedListReplyTargetAvailabilityReporter(
        replyTarget: replyTarget,
        currentVaultID: vault.vaultID,
        allEdgeIDs: allEdgeIDs,
        onAvailabilityChange: onReplyTargetAvailabilityChange
      )
    }
    .navigationDestination(for: SavedListNavigationRoute.self) { route in
      switch route {
      case .locations:
        VaultSavedLocationsMapView(pins: locationPins)
          .appZoomNavigationTransition(
            sourceID: VaultSavedLocationsMapTransition.id,
            in: navigationTransitionNamespace
          )
      }
    }
  }

  /// Builds the map header and one lazy stack whose direct children are the
  /// live recursive row views. A root adapter keeps its stable id even when the
  /// root card is filtered out so the two-stage Reply reveal can materialize its
  /// descendants first.
  private func savedListContent(
    sections: [VaultSavedDaySection],
    locationPins: [VaultSavedLocationPin]
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if locationPins.isEmpty == false {
        VaultSavedLocationsMapNavigationHeader(
          pins: locationPins,
          transitionNamespace: navigationTransitionNamespace
        )
        .padding(.horizontal, savedListPadding)
      }

      LazyVStack(
        alignment: .leading,
        spacing: VaultSavedEntryTreeMetrics.nodeSpacing,
        pinnedViews: .sectionHeaders
      ) {
        ForEach(sections) { section in
          Section {
            ForEach(section.roots, id: \.id) { root in
              VaultSavedEntryTreeRows(
                edge: root,
                store: vault.contentStore,
                depth: 0,
                selectedContentKind: selectedContentKind,
                ancestorEdgeIDs: [],
                ownerRootEdgeID: root.id,
                onReply: onSelectReplyTarget,
                onShare: onShare,
                onEdit: onEdit,
                onRequestDelete: onRequestDelete,
                onToggleTodoCompletion: onToggleTodoCompletion
              )
              .id(root.id)
            }
          } header: {
            StickyContainer { isSticked in
              VaultSavedDayHeader(
                isSticked: isSticked,
                day: section.day
              )
              .padding(.vertical, daySectionTopSpacing)
            }
          }
        }
      }
    }
  }

  /// Location annotations for matching placements in visible rooted trees.
  ///
  /// Locations belong to authored cards, so duplicate placements collapse by
  /// card id just as they did in the previous Home implementation.
  private static func savedLocationPins(
    for edges: [JournalVault.CardEdge]
  ) -> [VaultSavedLocationPin] {
    var pinsByCardID: [UUID: VaultSavedLocationPin] = [:]

    for edge in edges {
      guard let card = edge.card, let coordinate = card.location else {
        continue
      }
      pinsByCardID[card.id] = VaultSavedLocationPin(
        id: card.id,
        coordinate: coordinate,
        createdAt: card.createdAt
      )
    }

    return pinsByCardID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
  }
}

/// Collects the active Home rows currently materialized by the lazy stack.
struct SavedListRenderedEdgeIDsPreferenceKey: PreferenceKey {
  static var defaultValue: Set<UUID> { [] }

  static func reduce(
    value: inout Set<UUID>,
    nextValue: () -> Set<UUID>
  ) {
    value.formUnion(nextValue())
  }
}

private struct StickyContainer<Content: View>: View {

  let content: (Bool) -> Content
  @State private var isSticked: Bool = false

  init(@ViewBuilder content: @escaping (Bool) -> Content) {
    self.content = content
  }

  var body: some View {
    content(isSticked)
      .onGeometryChange(for: Bool.self) {
        // 20pt is just approximate value
        return $0.frame(in: .scrollView).minY <= 20
      } action: { newValue in
        isSticked = newValue
      }
  }
}

/// Resolves one post-success reveal against Home's query, live tree, and lazy
/// layout state.
private struct SavedListScrollCoordinator: View {

  @Binding var request: SavedListScrollRequest?
  let allEdgeIDs: Set<UUID>
  let rootEdges: [JournalVault.CardEdge]
  let visibleRootEdgeIDs: Set<UUID>
  let selectedContentKind: JournalVault.Card.Kind?
  let renderedEdgeIDs: Set<UUID>
  let proxy: ScrollViewProxy

  var body: some View {
    let resolution = resolution

    Color.clear
      .frame(width: 0, height: 0)
      .task(id: resolution) {
        await apply(resolution)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  /// Coalesces volatile query and lazy-layout inputs into the next semantic
  /// action. Intermediate rendered-id sets that resolve identically therefore
  /// do not restart the task within one layout frame.
  private var resolution: SavedListScrollResolution? {
    guard let request else { return nil }
    let targetIsVisibleInOwnerRoot =
      rootEdges.first {
        $0.id == request.ownerRootEdgeID
      }.map { root in
        VaultSavedListTreeTraversal.containsVisiblePlacement(
          edgeID: request.targetEdgeID,
          in: root,
          selectedContentKind: selectedContentKind
        )
      } ?? false

    return request.resolution(
      allEdgeIDs: allEdgeIDs,
      visibleRootEdgeIDs: visibleRootEdgeIDs,
      targetIsVisibleInOwnerRoot: targetIsVisibleInOwnerRoot,
      renderedEdgeIDs: renderedEdgeIDs
    )
  }

  /// Crosses the current layout update boundary before applying the latest
  /// resolution. A changed resolution cancels this task before it can act on
  /// stale query or materialization state.
  private func apply(_ resolution: SavedListScrollResolution?) async {
    guard let resolution else { return }

    await Task.yield()
    guard Task.isCancelled == false else { return }

    switch resolution {
    case .waitForQuery:
      return
    case .materializeOwnerRoot(let ownerRootEdgeID):
      withAnimation(.smooth) {
        proxy.scrollTo(ownerRootEdgeID, anchor: .top)
      }
    case .revealRoot(let targetEdgeID):
      withAnimation(.smooth) {
        proxy.scrollTo(targetEdgeID, anchor: .top)
      }
      consumeRequest()
    case .revealReply(let targetEdgeID):
      withAnimation(.smooth) {
        proxy.scrollTo(targetEdgeID, anchor: .center)
      }
      consumeRequest()
    case .consumeWithoutScrolling:
      consumeRequest()
    }
  }

  private func consumeRequest() {
    request = nil
  }
}

/// Reports whether the detached Reply parent still exists in the selected
/// vault, independently of Home's active content filter.
private struct SavedListReplyTargetAvailabilityReporter: View {

  let replyTarget: SavedListReplyTarget?
  let currentVaultID: VaultID
  let allEdgeIDs: Set<UUID>
  let onAvailabilityChange: @MainActor (Bool) -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onChange(of: observation, initial: true) { _, observation in
        onAvailabilityChange(observation.isAvailable)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var observation: SavedListReplyTargetAvailabilityObservation {
    SavedListReplyTargetAvailabilityObservation(
      replyTarget: replyTarget,
      currentVaultID: currentVaultID,
      allEdgeIDs: allEdgeIDs
    )
  }
}

/// Equatable input keeps the availability callback synchronized when the Reply
/// target changes between two placements that are both currently available.
private struct SavedListReplyTargetAvailabilityObservation: Equatable {

  let replyTarget: SavedListReplyTarget?
  let currentVaultID: VaultID
  let allEdgeIDs: Set<UUID>

  var isAvailable: Bool {
    guard let replyTarget else { return true }
    guard replyTarget.vaultID == currentVaultID else { return false }
    return allEdgeIDs.contains(replyTarget.parentEdgeID)
  }
}

/// Native single-selection menu for the content types that can appear on Home.
private struct VaultSavedListContentFilterMenu: View {

  @Binding var selection: JournalVault.Card.Kind?
  @Environment(\.appPalette) var palette

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
      .tint(palette.onPrimaryContainer)
    } label: {
      Label("Filter Entries", systemImage: filterSymbolName)
        .labelStyle(.iconOnly)
    }
    .tint(isSelectionEnabled ? palette.tint : palette.onPrimaryContainer)
    .accessibilityLabel("Filter Entries")
    .accessibilityValue(accessibilityValue)
  }

  private var filterableKinds: [JournalVault.Card.Kind] {
    JournalVault.Card.Kind.allCases.filter(\.isAvailableInSavedListFilter)
  }

  private var isSelectionEnabled: Bool {
    selection != nil
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
