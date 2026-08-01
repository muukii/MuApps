//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Integrates preview sources, LUT management, and app information.
struct FargSettingsView: View {

  let library: LUTLibrary
  let defaultVideoFolder: DefaultVideoFolderStore
  let previewSamples: LUTPreviewSampleLibrary
  @Environment(\.dismiss) private var dismiss

  @State private var isImportingFiles = false
  @State private var isLinkingFolder = false
  @State private var pickedPreviewItem: PhotosPickerItem?
  @State private var pendingPreviewImage: PickedLUTPreviewImage?
  @State private var sampleLabel = ""
  @State private var isNamingSample = false
  @State private var sampleBeingRenamed: LUTPreviewSample?
  @State private var isRenamingSample = false
  @State private var sampleToDelete: LUTPreviewSample?
  @State private var isShowingSampleDeleteConfirmation = false
  @State private var previewSources: [LUTPreviewSample.ID: LUTPreviewSourceImage]
  @State private var lutPreviewModels = LUTPreviewModelStore()
  @State private var folderToUnlink: LUTFolderLink?
  @State private var isShowingUnlinkConfirmation = false
  @State private var errorMessage = ""
  @State private var isShowingError = false

  /// Creates Settings with an optional deterministic source for visual previews.
  init(
    library: LUTLibrary,
    defaultVideoFolder: DefaultVideoFolderStore,
    previewSamples: LUTPreviewSampleLibrary,
    initialPreviewSource: LUTPreviewSourceImage? = nil
  ) {
    self.library = library
    self.defaultVideoFolder = defaultVideoFolder
    self.previewSamples = previewSamples
    _previewSources = State(
      initialValue: initialPreviewSource.map {
        [LUTPreviewSample.colorTest.id: $0]
      } ?? [:]
    )
  }

  var body: some View {
    let previewSource = previewSources[previewSamples.selectedSampleID]
    let content = FargSettingsList(
      library: library,
      defaultVideoFolder: defaultVideoFolder,
      previewSamples: previewSamples,
      previewSources: previewSources,
      pickedPreviewItem: $pickedPreviewItem,
      onSelectSample: selectSample,
      onRenameSample: beginRenaming,
      onDeleteSample: beginDeleting,
      onSetDefaultVideoFolder: setDefaultVideoFolder,
      onClearDefaultVideoFolder: clearDefaultVideoFolder,
      onUnlinkFolder: beginUnlinking,
      onDeleteLUT: delete
    )

    let navigation = NavigationStack {
      content
        .refreshable {
          await library.refreshLinkedFolders()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          FargSettingsToolbar(
            onDone: { dismiss() },
            onImportLUTs: { isImportingFiles = true },
            onLinkFolder: { isLinkingFolder = true }
          )
        }
    }

    let fileImportPresentation = navigation
      .fileImporter(
        isPresented: $isImportingFiles,
        allowedContentTypes: LUTLibrary.importableContentTypes,
        allowsMultipleSelection: true
      ) { result in
        handleFileImport(result)
      }
      .fileImporter(
        isPresented: $isLinkingFolder,
        allowedContentTypes: [.folder]
      ) { result in
        handleFolderLink(result)
      }

    let samplePresentation = fileImportPresentation
      .onChange(of: pickedPreviewItem) { _, item in
        loadPickedPreviewImage(item)
      }
      .alert("Label Preview Sample", isPresented: $isNamingSample) {
        TextField("Sony S-Log3", text: $sampleLabel)
        Button("Add") {
          addPendingPreviewSample()
        }
        .disabled(isSampleLabelInvalid)
        Button("Cancel", role: .cancel) {
          discardPendingPreviewImage()
        }
      } message: {
        Text("Use a camera or Log profile name so the LUT result is unambiguous.")
      }
      .alert("Rename Preview Sample", isPresented: $isRenamingSample) {
        TextField("Sample label", text: $sampleLabel)
        Button("Save") {
          renameSample()
        }
        .disabled(isSampleLabelInvalid)
        Button("Cancel", role: .cancel) {
          sampleBeingRenamed = nil
        }
      }

    let destructivePresentation = samplePresentation
      .confirmationDialog(
        "Delete Preview Sample?",
        isPresented: $isShowingSampleDeleteConfirmation,
        presenting: sampleToDelete
      ) { sample in
        Button("Delete \(sample.label)", role: .destructive) {
          deleteSample(sample)
        }
        Button("Cancel", role: .cancel) {}
      } message: { sample in
        Text("The app-owned copy of \(sample.label) will be removed.")
      }
      .confirmationDialog(
        "Unlink LUT Folder?",
        isPresented: $isShowingUnlinkConfirmation,
        presenting: folderToUnlink
      ) { folder in
        Button("Unlink and Keep LUTs") {
          unlink(folder)
        }
        Button("Cancel", role: .cancel) {}
      } message: { folder in
        Text(
          "Färg will stop checking \(folder.displayName). Its current LUT copies will remain in the library."
        )
      }

    return destructivePresentation
      .environment(lutPreviewModels)
      .alert("Settings Error", isPresented: $isShowingError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .task {
        await library.refreshLinkedFolders()
      }
      .task(
        id: PreviewSourcesTaskID(
          selectedSampleID: previewSamples.selectedSampleID,
          sampleIDs: previewSamples.samples.map(\.id)
        )
      ) {
        await loadPreviewSources()
      }
      .onChange(of: previewSource?.id, initial: true) { _, sourceID in
        lutPreviewModels.updateContext(
          LUTPreviewContextID(
            sourceID: sourceID,
            libraryRevision: library.revision
          )
        )
      }
      .onChange(of: library.revision, initial: true) { _, revision in
        lutPreviewModels.synchronize(lutIDs: library.luts.map(\.id))
        lutPreviewModels.updateContext(
          LUTPreviewContextID(
            sourceID: previewSource?.id,
            libraryRevision: revision
          )
        )
      }
      .onDisappear {
        discardPendingPreviewImage()
      }
  }

  private var isSampleLabelInvalid: Bool {
    sampleLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func loadPickedPreviewImage(_ item: PhotosPickerItem?) {
    guard let item else { return }
    Task {
      defer { pickedPreviewItem = nil }
      do {
        guard
          let image = try await item.loadTransferable(
            type: PickedLUTPreviewImage.self
          )
        else {
          return
        }
        pendingPreviewImage = image
        sampleLabel = ""
        isNamingSample = true
      } catch {
        present(error)
      }
    }
  }

  private func addPendingPreviewSample() {
    guard let pendingPreviewImage else { return }
    let label = sampleLabel
    self.pendingPreviewImage = nil
    Task {
      defer {
        try? FileManager.default.removeItem(at: pendingPreviewImage.url)
      }
      do {
        try await previewSamples.addSample(
          from: pendingPreviewImage.url,
          label: label
        )
      } catch {
        present(error)
      }
    }
  }

  private func discardPendingPreviewImage() {
    guard let pendingPreviewImage else { return }
    try? FileManager.default.removeItem(at: pendingPreviewImage.url)
    self.pendingPreviewImage = nil
  }

  private func selectSample(_ sample: LUTPreviewSample) {
    do {
      try previewSamples.select(id: sample.id)
    } catch {
      present(error)
    }
  }

  private func beginRenaming(_ sample: LUTPreviewSample) {
    sampleBeingRenamed = sample
    sampleLabel = sample.label
    isRenamingSample = true
  }

  private func renameSample() {
    guard let sampleBeingRenamed else { return }
    do {
      try previewSamples.rename(sampleBeingRenamed, label: sampleLabel)
      self.sampleBeingRenamed = nil
    } catch {
      present(error)
    }
  }

  private func beginDeleting(_ sample: LUTPreviewSample) {
    sampleToDelete = sample
    isShowingSampleDeleteConfirmation = true
  }

  private func deleteSample(_ sample: LUTPreviewSample) {
    do {
      try previewSamples.delete(sample)
      sampleToDelete = nil
    } catch {
      present(error)
    }
  }

  private func loadPreviewSources() async {
    let requestedSamples = previewSamples.samples
    let validSampleIDs = Set(requestedSamples.map(\.id))
    previewSources = previewSources.filter { validSampleIDs.contains($0.key) }

    var samplesToLoad = requestedSamples
    if let selectedIndex = samplesToLoad.firstIndex(
      where: { $0.id == previewSamples.selectedSampleID }
    ) {
      let selectedSample = samplesToLoad.remove(at: selectedIndex)
      samplesToLoad.insert(selectedSample, at: 0)
    }

    for sample in samplesToLoad where previewSources[sample.id] == nil {
      do {
        let source = try await previewSamples.loadImage(for: sample)
        guard
          Task.isCancelled == false,
          previewSamples.samples.contains(where: {
            $0.id == sample.id && $0.source == sample.source
          })
        else {
          return
        }
        previewSources[sample.id] = source
      } catch is CancellationError {
        return
      } catch {
        guard Task.isCancelled == false else { return }
        if previewSamples.selectedSampleID == sample.id {
          previewSources[sample.id] = nil
          present(error)
        }
      }
    }
  }

  private func handleFileImport(_ result: Result<[URL], any Error>) {
    switch result {
    case .success(let urls):
      for url in urls {
        do {
          try library.importLUT(from: url)
        } catch {
          present(error)
        }
      }
    case .failure(let error):
      present(error)
    }
  }

  private func handleFolderLink(_ result: Result<URL, any Error>) {
    switch result {
    case .success(let url):
      Task {
        do {
          try await library.linkFolder(from: url)
        } catch {
          present(error)
        }
      }
    case .failure(let error):
      present(error)
    }
  }

  private func delete(_ lut: LUT) {
    do {
      try library.delete(lut)
    } catch {
      present(error)
    }
  }

  private func setDefaultVideoFolder(_ url: URL) {
    do {
      try defaultVideoFolder.setFolder(from: url)
    } catch {
      present(error)
    }
  }

  private func clearDefaultVideoFolder() {
    do {
      try defaultVideoFolder.clearFolder()
    } catch {
      present(error)
    }
  }

  private func beginUnlinking(folderID: String) {
    guard let folder = library.linkedFolders.first(
      where: { $0.id == folderID }
    ) else {
      return
    }
    folderToUnlink = folder
    isShowingUnlinkConfirmation = true
  }

  private func unlink(_ folder: LUTFolderLink) {
    do {
      try library.unlinkFolder(folder)
      folderToUnlink = nil
    } catch {
      present(error)
    }
  }

  private func present(_ error: any Error) {
    errorMessage = error.localizedDescription
    isShowingError = true
  }
}

/// Navigation actions for dismissing Settings and adding LUT sources.
private struct FargSettingsToolbar: ToolbarContent {

  let onDone: @MainActor @Sendable () -> Void
  let onImportLUTs: @MainActor @Sendable () -> Void
  let onLinkFolder: @MainActor @Sendable () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button("Done", action: onDone)
    }
    ToolbarItem(placement: .topBarTrailing) {
      Menu {
        Button(action: onImportLUTs) {
          Label("Import LUT Files", systemImage: "doc.badge.plus")
        }
        Button(action: onLinkFolder) {
          Label("Link LUT Folder", systemImage: "folder.badge.plus")
        }
      } label: {
        Image(systemName: "plus")
      }
      .accessibilityLabel("Add LUTs")
    }
  }
}

/// Orders the independently invalidating sections of the Settings list.
private struct FargSettingsList: View {

  let library: LUTLibrary
  let defaultVideoFolder: DefaultVideoFolderStore
  let previewSamples: LUTPreviewSampleLibrary
  let previewSources: [LUTPreviewSample.ID: LUTPreviewSourceImage]
  @Binding var pickedPreviewItem: PhotosPickerItem?
  let onSelectSample: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onRenameSample: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onDeleteSample: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onSetDefaultVideoFolder: @MainActor @Sendable (URL) -> Void
  let onClearDefaultVideoFolder: @MainActor @Sendable () -> Void
  let onUnlinkFolder: @MainActor @Sendable (String) -> Void
  let onDeleteLUT: @MainActor @Sendable (LUT) -> Void

  var body: some View {
    let previewSource = previewSources[previewSamples.selectedSampleID]

    List {
      DefaultVideoFolderSection(
        folder: defaultVideoFolder.folder,
        onSelect: onSetDefaultVideoFolder,
        onClear: onClearDefaultVideoFolder
      )

      PreviewSamplesSection(
        samples: previewSamples.samples,
        selectedSampleID: previewSamples.selectedSampleID,
        previewSources: previewSources,
        pickedItem: $pickedPreviewItem,
        onSelect: onSelectSample,
        onRename: onRenameSample,
        onDelete: onDeleteSample
      )

      ImportedLUTCollectionSection(
        luts: library.importedLUTs,
        previewSource: previewSource,
        library: library,
        onDelete: onDeleteLUT
      )

      LinkedLUTFoldersSection(
        collections: library.linkedFolderCollections,
        errors: library.linkedFolderErrors,
        syncProgress: library.linkedFolderSyncProgress,
        isRefreshing: library.isRefreshingLinkedFolders,
        previewSource: previewSource,
        library: library,
        onUnlink: onUnlinkFolder
      )

      Section("About") {
        Link(destination: FargExternalLinks.privacyPolicy) {
          Label("Privacy Policy", systemImage: "hand.raised")
        }
      }
    }
  }
}

/// Configures the Files directory used as the starting point for video import.
private struct DefaultVideoFolderSection: View {

  let folder: DefaultVideoFolder?
  let onSelect: @MainActor @Sendable (URL) -> Void
  let onClear: @MainActor @Sendable () -> Void

  @State private var isSelectingFolder = false
  @State private var selectionErrorMessage: String?

  var body: some View {
    Section {
      if let folder {
        LabeledContent {
          VStack(alignment: .trailing, spacing: 2) {
            Text(folder.displayName)
            if let volumeName = folder.volumeName, volumeName != folder.displayName {
              Text(volumeName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } label: {
          Label("Default Folder", systemImage: "folder")
        }

        Button("Choose Another Folder", systemImage: "folder.badge.plus") {
          isSelectingFolder = true
        }

        Button(
          "Clear Default Folder",
          systemImage: "xmark.circle",
          role: .destructive,
          action: onClear
        )
      } else {
        Button("Choose Default Folder", systemImage: "folder.badge.plus") {
          isSelectingFolder = true
        }
      }
    } header: {
      Text("Video Import")
    } footer: {
      Text(
        "Files opens in this folder when its storage is available. Otherwise, Files uses its normal starting location."
      )
    }
    .fileImporter(
      isPresented: $isSelectingFolder,
      allowedContentTypes: [.folder]
    ) { result in
      switch result {
      case .success(let url):
        onSelect(url)
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          selectionErrorMessage = error.localizedDescription
        }
      }
    }
    .alert(
      "Couldn't Choose Folder",
      isPresented: Binding(
        get: { selectionErrorMessage != nil },
        set: { if $0 == false { selectionErrorMessage = nil } }
      ),
      presenting: selectionErrorMessage
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
  }
}

/// Reprioritizes decoding when the active sample or source membership changes.
private struct PreviewSourcesTaskID: Hashable {
  var selectedSampleID: LUTPreviewSample.ID
  var sampleIDs: [LUTPreviewSample.ID]
}

/// Selects and manages the common labeled input used by every LUT result.
private struct PreviewSamplesSection: View {

  let samples: [LUTPreviewSample]
  let selectedSampleID: LUTPreviewSample.ID
  let previewSources: [LUTPreviewSample.ID: LUTPreviewSourceImage]
  @Binding var pickedItem: PhotosPickerItem?
  let onSelect: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onRename: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onDelete: @MainActor @Sendable (LUTPreviewSample) -> Void

  var body: some View {
    Section {
      PreviewSampleRail(
        samples: samples,
        selectedSampleID: selectedSampleID,
        previewSources: previewSources,
        pickedItem: $pickedItem,
        onSelect: onSelect,
        onRename: onRename,
        onDelete: onDelete
      )
      .padding(.vertical, 8)
    } header: {
      Text("LUT Preview Source")
    } footer: {
      Text(
        "Tap a sample to apply it to every LUT below. Touch and hold a custom sample to rename or delete it."
      )
    }
  }
}

/// Presents preview sources as a freely browsable, tap-selected strip.
private struct PreviewSampleRail: View {

  let samples: [LUTPreviewSample]
  let selectedSampleID: LUTPreviewSample.ID
  let previewSources: [LUTPreviewSample.ID: LUTPreviewSourceImage]
  @Binding var pickedItem: PhotosPickerItem?
  let onSelect: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onRename: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onDelete: @MainActor @Sendable (LUTPreviewSample) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: 12) {
        ForEach(samples) { sample in
          PreviewSampleRailItem(
            sample: sample,
            previewSource: previewSources[sample.id],
            isSelected: selectedSampleID == sample.id,
            onSelect: onSelect,
            onRename: onRename,
            onDelete: onDelete
          )
        }

        PreviewSampleAddItem(pickedItem: $pickedItem)
      }
    }
    .contentMargins(.horizontal, 8, for: .scrollContent)
    .scrollIndicators(.hidden)
  }
}

/// Adds per-sample editing actions without coupling them to the active sample.
private struct PreviewSampleRailItem: View {

  let sample: LUTPreviewSample
  let previewSource: LUTPreviewSourceImage?
  let isSelected: Bool
  let onSelect: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onRename: @MainActor @Sendable (LUTPreviewSample) -> Void
  let onDelete: @MainActor @Sendable (LUTPreviewSample) -> Void

  var body: some View {
    if sample.canEdit {
      PreviewSampleSelectionButton(
        sample: sample,
        previewSource: previewSource,
        isSelected: isSelected,
        onSelect: onSelect
      )
      .contextMenu {
        Button {
          onRename(sample)
        } label: {
          Label("Rename Sample", systemImage: "pencil")
        }

        Button(role: .destructive) {
          onDelete(sample)
        } label: {
          Label("Delete Sample", systemImage: "trash")
        }
      }
      .accessibilityAction(named: "Rename Sample") {
        onRename(sample)
      }
      .accessibilityAction(named: "Delete Sample") {
        onDelete(sample)
      }
    } else {
      PreviewSampleSelectionButton(
        sample: sample,
        previewSource: previewSource,
        isSelected: isSelected,
        onSelect: onSelect
      )
    }
  }
}

/// Selects one preview source while making the persisted state visible.
private struct PreviewSampleSelectionButton: View {

  let sample: LUTPreviewSample
  let previewSource: LUTPreviewSourceImage?
  let isSelected: Bool
  let onSelect: @MainActor @Sendable (LUTPreviewSample) -> Void

  var body: some View {
    Button {
      onSelect(sample)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        PreviewSampleThumbnail(
          previewSource: previewSource,
          isSelected: isSelected
        )

        Text(sample.label)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
          .lineLimit(1)
      }
      .frame(width: 144)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sample.label)
    .accessibilityHint("Applies this sample to every LUT preview")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Draws one source thumbnail and its explicit selection treatment.
private struct PreviewSampleThumbnail: View {

  let previewSource: LUTPreviewSourceImage?
  let isSelected: Bool

  var body: some View {
    ZStack {
      Color.secondary.opacity(0.12)

      if let previewSource {
        Image(decorative: previewSource.image, scale: 1)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.title2)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: 144, height: 90)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
          lineWidth: isSelected ? 3 : 1
        )
    }
    .overlay(alignment: .topTrailing) {
      if isSelected {
        Image(systemName: "checkmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .frame(width: 24, height: 24)
          .background(Color.accentColor, in: Circle())
          .padding(8)
      }
    }
  }
}

/// Keeps importing adjacent to the samples by placing it at the strip's end.
private struct PreviewSampleAddItem: View {

  @Binding var pickedItem: PhotosPickerItem?

  var body: some View {
    PhotosPicker(
      selection: $pickedItem,
      matching: .images
    ) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.08))

          Image(systemName: "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .frame(width: 144, height: 90)
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
              Color.secondary.opacity(0.35),
              style: StrokeStyle(lineWidth: 1, dash: [4])
            )
        }

        Text("Add Sample")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 144)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add Sample Image")
  }
}

/// The linked directories and their current synchronization state.
fileprivate struct LinkedLUTFoldersSection: View {

  let collections: [LUTFolderCollection]
  let errors: [String: String]
  let syncProgress: [String: LUTFolderSyncProgress]
  let isRefreshing: Bool
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary
  let onUnlink: @MainActor @Sendable (String) -> Void

  var body: some View {
    Section {
      if collections.isEmpty {
        ContentUnavailableView(
          "No Linked Folders",
          systemImage: "folder",
          description: Text(
            "Link a Files folder to import and keep its LUTs synchronized automatically."
          )
        )
      } else {
        ForEach(collections) { collection in
          LinkedLUTFolderDisclosure(
            folderName: collection.name,
            lastSyncedAt: collection.lastSyncedAt,
            luts: collection.luts,
            folders: collection.folders,
            syncProgress: syncProgress[collection.id],
            errorMessage: errors[collection.id],
            previewSource: previewSource,
            library: library
          )
          .swipeActions {
            Button {
              onUnlink(collection.id)
            } label: {
              Label("Unlink", systemImage: "link.badge.minus")
            }
            .tint(.orange)
          }
        }
      }
    } header: {
      HStack {
        Text("Linked Folders")
        Spacer()
        if isRefreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Scanning linked LUT folders")
        }
      }
    } footer: {
      Text(
        "Linked folders are synchronized automatically while the app is active. Pull to refresh at any time."
      )
    }
  }
}

/// One linked root directory with its synchronized Files hierarchy.
fileprivate struct LinkedLUTFolderDisclosure: View {

  let folderName: String
  let lastSyncedAt: Date?
  let luts: [LUT]
  let folders: [LUTFolderNode]
  let syncProgress: LUTFolderSyncProgress?
  let errorMessage: String?
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary

  var body: some View {
    DisclosureGroup {
      if luts.isEmpty, folders.isEmpty {
        Text("No supported LUTs")
          .foregroundStyle(.secondary)
      } else {
        LUTFolderContents(
          luts: luts,
          folders: folders,
          previewSource: previewSource,
          library: library
        )
      }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "folder")
          .foregroundStyle(.tint)

        VStack(alignment: .leading, spacing: 3) {
          Text(folderName)
            .font(.body)

          if let syncProgress {
            Text(syncProgress.description)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else if let errorMessage {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          } else if let lastSyncedAt {
            Text(
              "Synced \(lastSyncedAt, format: .relative(presentation: .named))",
              comment: "Status showing when a linked LUT folder was most recently synchronized."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Text("Waiting to sync")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

private extension LUTFolderSyncProgress {

  var description: String {
    switch phase {
    case .scanning:
      return "Scanning folder…"
    case .copying:
      return countedDescription(verb: "Copying")
    case .validating:
      return countedDescription(verb: "Validating")
    case .installing:
      return countedDescription(verb: "Installing")
    }
  }

  func countedDescription(verb: String) -> String {
    guard let totalCount else {
      return "\(verb)…"
    }
    return "\(verb) \(completedCount) of \(totalCount)…"
  }
}

/// The direct LUT files and nested directories below one linked directory.
fileprivate struct LUTFolderContents: View {

  let luts: [LUT]
  let folders: [LUTFolderNode]
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary

  var body: some View {
    ForEach(luts) { lut in
      LUTLibraryRow(
        lut: lut,
        previewSource: previewSource,
        library: library
      )
    }

    ForEach(folders) { folder in
      LUTSubfolderDisclosure(
        folderName: folder.name,
        luts: folder.luts,
        folders: folder.folders,
        previewSource: previewSource,
        library: library
      )
    }
  }
}

/// One nested linked directory that preserves its Files path position.
fileprivate struct LUTSubfolderDisclosure: View {

  let folderName: String
  let luts: [LUT]
  let folders: [LUTFolderNode]
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary

  var body: some View {
    DisclosureGroup {
      LUTFolderContents(
        luts: luts,
        folders: folders,
        previewSource: previewSource,
        library: library
      )
    } label: {
      Label(folderName, systemImage: "folder")
    }
  }
}

/// LUT files imported independently from linked directories.
fileprivate struct ImportedLUTCollectionSection: View {

  let luts: [LUT]
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary
  let onDelete: @MainActor @Sendable (LUT) -> Void

  var body: some View {
    Section {
      if luts.isEmpty {
        Text("No imported LUTs")
          .foregroundStyle(.secondary)
      } else {
        ForEach(luts) { lut in
          LUTLibraryRow(
            lut: lut,
            previewSource: previewSource,
            library: library
          )
          .swipeActions {
            if lut.canDeleteManually {
              Button(role: .destructive) {
                onDelete(lut)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
    } header: {
      Text("Imported LUTs")
    } footer: {
      Text(
        "Import LUT files or link a LUT folder from Files with the Add LUTs button. Linked LUTs remain organized by folder."
      )
    }
  }
}

/// A stable, single-root list row for one app-owned LUT copy.
fileprivate struct LUTLibraryRow: View {

  let lut: LUT
  let previewSource: LUTPreviewSourceImage?
  let library: LUTLibrary

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbolName)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(lut.name)
          Text("\(formatTitle) • \(lut.dimension)³")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      LUTPreviewImageView(
        source: previewSource,
        lut: lut,
        library: library
      )
      .aspectRatio(16 / 10, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .accessibilityLabel("\(lut.name) applied preview")
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }

  private var symbolName: String {
    switch lut.format {
    case .cube:
      return "cube"
    case .image:
      return "photo"
    }
  }

  private var formatTitle: LocalizedStringResource {
    switch lut.format {
    case .cube:
      return "Cube"
    case .image:
      return "Image"
    }
  }
}

/// Stable public destinations exposed from the integrated Settings screen.
private enum FargExternalLinks {

  static let privacyPolicy = URL(
    string: "https://muukii.craft.me/sBSocrsnWchgZ1"
  )!
}

#Preview("Settings") {
  FargSettingsView(
    library: LUTLibrary(),
    defaultVideoFolder: DefaultVideoFolderStore(),
    previewSamples: LUTPreviewSampleLibrary(),
    initialPreviewSource: LUTPreviewSampleLibrary.makePreviewSource()
  )
}
