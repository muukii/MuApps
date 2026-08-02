//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// A horizontal LUT selector rendered from the latest stopped source frame.
///
/// The source stays fixed while video playback continues. This keeps the
/// selector useful without evaluating every LUT for every playback frame.
struct LUTStripView: View {

  let contentPadding: CGFloat
  let library: LUTLibrary
  let source: LUTPreviewSourceImage?
  let exposure: ExposureAdjustment
  @Binding var selected: LUT?

  var body: some View {
    HorizontalFolderView(
      items: rootItems,
      initialPath: selectedFolderPath,
      itemView: itemView,
      folderView: { name in
        LUTFolderCell(title: name)
      }
    )
    .id(selectorIdentity)
    .padding(.horizontal, contentPadding)
  }

  /// The top-level selector entries keep linked LUTs out of the flat root.
  private var rootItems: [FileSystemNode<LUTStripItem>] {
    let importedItems = library.importedLUTs.map {
      FileSystemNode<LUTStripItem>.file(value: .lut($0))
    }
    let linkedFolderItems = library.linkedFolderCollections.map { collection in
      FileSystemNode<LUTStripItem>.directory(
        .init(
          id: collection.id,
          name: collection.name,
          contents: folderContents(
            luts: collection.luts,
            folders: collection.folders
          )
        )
      )
    }
    return [.file(value: .original)] + importedItems + linkedFolderItems
  }

  /// Converts the persisted linked-folder projection into navigable entries.
  private func folderContents(
    luts: [LUT],
    folders: [LUTFolderNode]
  ) -> [FileSystemNode<LUTStripItem>] {
    let lutItems = luts.map { lut in
      FileSystemNode<LUTStripItem>.file(value: .lut(lut))
    }
    let folderItems = folders.map { folder in
      FileSystemNode<LUTStripItem>.directory(
        .init(
          id: folder.id,
          name: folder.name,
          contents: folderContents(
            luts: folder.luts,
            folders: folder.folders
          )
        )
      )
    }
    return lutItems + folderItems
  }

  /// The directory ID path containing the selected linked LUT, including root.
  private var selectedFolderPath: [String] {
    guard
      let selected,
      let origin = selected.linkedFolderOrigin,
      let collection = library.linkedFolderCollections.first(
        where: { $0.id == origin.folderID }
      )
    else {
      return []
    }

    let components = origin.relativePath
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    guard components.isEmpty == false else { return [] }
    let directoryComponents = Array(components.dropLast())
    let nestedFolderIDs = directoryComponents.indices.map { index in
      let relativePath = directoryComponents[...index].joined(separator: "/")
      return "\(origin.folderID):\(relativePath)"
    }
    return [collection.id] + nestedFolderIDs
  }

  /// Rebuilds the navigation stack when synchronized LUT metadata changes.
  private var selectorIdentity: LUTSelectorIdentity {
    LUTSelectorIdentity(
      libraryRevision: library.revision,
      folderPath: selectedFolderPath
    )
  }

  @ViewBuilder
  private func itemView(for item: LUTStripItem) -> some View {
    switch item {
    case .original:
      OriginalCell(
        title: "No LUT",
        source: source,
        library: library,
        exposure: exposure,
        isSelected: selected == nil
      ) {
        selected = nil
      }

    case .lut(let lut):
      LUTPreviewCell(
        title: lut.name,
        subtitle: originLabel(for: lut),
        source: source,
        lut: lut,
        library: library,
        exposure: exposure,
        isSelected: selected?.id == lut.id
      ) {
        selected = lut
      }
    }
  }

  // TODO: looks performance bad
  private func originLabel(for lut: LUT) -> String? {
    guard let origin = lut.linkedFolderOrigin else {
      return nil
    }
    let rootName = library.linkedFolders.first {
      $0.id == origin.folderID
    }?.displayName
    let parent = URL(filePath: origin.relativePath)
      .deletingLastPathComponent()
      .path(percentEncoded: false)
    let components = [rootName, parent == "." ? nil : parent]
      .compactMap { $0 }
      .filter { $0.isEmpty == false }
    return components.isEmpty ? "Linked" : components.joined(separator: " / ")
  }
}

/// A root or leaf entry displayed by the hierarchical LUT selector.
private enum LUTStripItem: Hashable {
  case original
  case lut(LUT)
}

/// Identity for the current LUT tree and its externally selected folder path.
private struct LUTSelectorIdentity: Hashable {

  let libraryRevision: UInt
  let folderPath: [String]
}

/// One linked-folder directory in the editor's horizontal navigation stack.
private struct LUTFolderCell: View {

  let title: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Image(systemName: "folder.fill")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 64, height: 64)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

      Text(title)
        .font(.caption)
        .foregroundStyle(.primary)
        .lineLimit(1)
    }
    .frame(width: 64)
    .contentShape(Rectangle())
  }
}

private struct OriginalCell: View {

  let title: String
  let source: LUTPreviewSourceImage?
  let library: LUTLibrary
  let exposure: ExposureAdjustment
  let isSelected: Bool
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        LUTPreviewImageView(
          source: source,
          lut: nil,
          library: library,
          exposure: exposure
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .selectionOverlay(isSelected: isSelected)
        .aspectRatio(1, contentMode: .fill)

        Text(title)
          .font(.caption.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
      }
      .frame(width: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// One preview-backed LUT choice in the editor.
private struct LUTPreviewCell: View {

  let title: String
  let subtitle: String?
  let source: LUTPreviewSourceImage?
  let lut: LUT?
  // TODO: shold not have this directly
  let library: LUTLibrary
  let exposure: ExposureAdjustment
  let isSelected: Bool
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        LUTPreviewImageView(
          source: source,
          lut: lut,
          library: library,
          exposure: exposure
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .selectionOverlay(isSelected: isSelected)
        .aspectRatio(1, contentMode: .fill)

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)

          if let subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else if source == nil {
            Text("Pause to preview")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }
      .frame(width: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(subtitle ?? "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

#Preview("LUT strip") {
  @Previewable @State var selected: LUT?
  @Previewable @State var previewModels = LUTPreviewModelStore()
  let library = LUTLibrary()
  let source = LUTPreviewSampleLibrary.makePreviewSource()

  LUTStripView(
    contentPadding: 16,
    library: library,
    source: source,
    exposure: .neutral,
    selected: $selected
  )
  .environment(previewModels)
  .onAppear {
    previewModels.synchronize(lutIDs: library.luts.map(\.id))
    previewModels.updateContext(
      LUTPreviewContextID(
        sourceID: source?.id,
        libraryRevision: library.revision
      )
    )
  }
  .padding()
  .background(.background)
}
