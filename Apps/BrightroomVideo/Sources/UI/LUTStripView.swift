//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// A horizontal selector of the user's LUTs, with an "Original" (no LUT) option.
struct LUTStripView: View {

  let library: LUTLibrary
  @Binding var selected: LUT?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        chip(title: "Original", isSelected: selected == nil) {
          selected = nil
        }

        ForEach(library.luts) { lut in
          chip(title: lut.name, isSelected: selected?.id == lut.id) {
            selected = lut
          }
        }
      }
      .padding(.horizontal, 2)
    }
  }

  private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline.weight(isSelected ? .semibold : .regular))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
          Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground)))
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
    .buttonStyle(.plain)
  }
}
