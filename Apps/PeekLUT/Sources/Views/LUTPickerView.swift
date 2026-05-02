import MuDesignSystem
import SwiftUI

struct LUTPickerView: View {

  let luts: [LUT]
  @Binding var selection: LUT.ID?
  let onImportTap: () -> Void

  @EnvironmentObject private var thumbnailCache: LUTThumbnailCache

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        noneCell
        ForEach(luts) { lut in
          cell(for: lut)
        }
        importCell
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private var noneCell: some View {
    Button {
      selection = nil
    } label: {
      VStack(spacing: 6) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 64, height: 64)
          Image(systemName: "circle.slash")
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selection == nil ? MuColors.primary : .clear, lineWidth: 2)
        )
        Text("None")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
  }

  private func cell(for lut: LUT) -> some View {
    Button {
      selection = lut.id
    } label: {
      VStack(spacing: 6) {
        Group {
          if let image = thumbnailCache.thumbnail(for: lut.id) {
            Image(uiImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Color.gray.opacity(0.2)
          }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selection == lut.id ? MuColors.primary : .clear, lineWidth: 2)
        )
        Text(lut.name)
          .font(.caption2)
          .lineLimit(1)
          .foregroundStyle(.primary)
          .frame(maxWidth: 76)
      }
    }
    .buttonStyle(.plain)
  }

  private var importCell: some View {
    Button(action: onImportTap) {
      VStack(spacing: 6) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 64, height: 64)
          Image(systemName: "plus")
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        Text("Import")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
  }
}
