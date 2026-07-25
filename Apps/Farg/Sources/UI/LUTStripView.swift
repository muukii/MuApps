//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI
import ScrollEdgeEffect

/// A horizontal LUT selector rendered from the latest stopped source frame.
///
/// The source stays fixed while video playback continues. This keeps the
/// selector useful without evaluating every LUT for every playback frame.
struct LUTStripView: View {

  let library: LUTLibrary
  let source: LUTPreviewSourceImage?
  @Binding var selected: LUT?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(alignment: .top, spacing: 10) {
          OriginalCell(
            title: "Original",
            subtitle: nil,
            source: source,
            lut: nil,
            library: library,
            isSelected: selected == nil
          ) {
            selected = nil
          }
          .id(LUTStripItemID.original)

          ForEach(library.luts) { lut in
            LUTPreviewCell(
              title: lut.name,
              subtitle: originLabel(for: lut),
              source: source,
              lut: lut,
              library: library,
              isSelected: selected?.id == lut.id
            ) {
              selected = lut
            }
            .id(LUTStripItemID.lut(lut.id))
          }
        }
      }
      .scrollEdgeEffect(edges: .horizontal)
      .onAppear {
        proxy.scrollTo(selectedItemID, anchor: .center)
      }
      .onChange(of: selectedItemID) { _, itemID in
        withAnimation(.snappy) {
          proxy.scrollTo(itemID, anchor: .center)
        }
      }
    }
    .frame(height: 126)
  }

  private var selectedItemID: LUTStripItemID {
    selected.map { .lut($0.id) } ?? .original
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

/// Stable anchors used to keep the active look visible in a large collection.
private enum LUTStripItemID: Hashable {
  case original
  case lut(String)
}

private struct OriginalCell: View {
  
  let title: String
  let subtitle: String?
  let source: LUTPreviewSourceImage?
  let lut: LUT?
  // TODO: shold not have this directly
  let library: LUTLibrary
  let isSelected: Bool
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        if let source {
          Image(decorative: source.image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .overlay {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                  isSelected ? EditorPalette.primary : EditorPalette.hairline,
                  lineWidth: isSelected ? 2 : 1
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(EditorPalette.primary)
            .lineLimit(1)

          if let subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(EditorPalette.secondary)
              .lineLimit(1)
          } else if source == nil {
            Text("Pause to preview")
              .font(.caption2)
              .foregroundStyle(EditorPalette.secondary)
              .lineLimit(1)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(subtitle ?? "")
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
  let isSelected: Bool
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        Color.clear
          .overlay {
            LUTPreviewImageView(
              source: source,
              lut: lut,
              library: library
            )          
          }
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(
                isSelected ? EditorPalette.primary : EditorPalette.hairline,
                lineWidth: isSelected ? 2 : 0
              )
          }
          .aspectRatio(1, contentMode: .fit)

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(EditorPalette.primary)
            .lineLimit(1)

          if let subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(EditorPalette.secondary)
              .lineLimit(1)
          } else if source == nil {
            Text("Pause to preview")
              .font(.caption2)
              .foregroundStyle(EditorPalette.secondary)
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
    library: library,
    source: source,
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
  .background(EditorPalette.chrome)
}
