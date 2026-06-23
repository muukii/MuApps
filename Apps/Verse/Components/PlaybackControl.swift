//
//  PlaybackControl.swift
//  Verse
//
//  Created by Hiroshi Kimura on 2026/06/21.
//  Copyright © 2026 muukii. All rights reserved.
//

import Playgrounds
import SwiftUI

public struct PlaybackControl: View {

  public var body: some View {

    HStack(spacing: 6) {
      Image(systemName: "play.fill")
        .resizable()
        .frame(width: 12, height: 12)
      Progress()
        .frame(idealWidth: 24)
      Text("\(30 * 60, format: RemainingDurationFormat())")
        .font(.caption)
        .fontWeight(.medium)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background {
      Capsule()
        .fill(.thinMaterial)
    }
    .fixedSize()
    .foregroundStyle(.tint)

  }

  private struct Progress: View {

    let progress: CGFloat = 0.5

    var body: some View {
      ZStack(alignment: .leading) {
        Capsule()
          .foregroundStyle(.tertiary)
          .overlay {
            GeometryReader { proxy in
              Capsule()
                .foregroundStyle(.primary)
                .frame(width: proxy.size.width * self.progress)
            }
          }
      }
      .frame(height: 4)
    }

  }

  struct RemainingDurationFormat: FormatStyle {

    private let style = Duration.UnitsFormatStyle(
      allowedUnits: [.hours, .minutes],
      width: .narrow,
      maximumUnitCount: 2,
      fractionalPart: .hide(rounded: .down)
    )

    func format(_ seconds: Int64) -> String {
      let duration = Duration(
        secondsComponent: max(0, seconds),
        attosecondsComponent: 0
      )
            
      return style.format(duration)
    }
    
  }
}

#Playground {

}

#Preview {
  ZStack {
    Color.green
    PlaybackControl()
  }
}

#Preview {
  Text("Hello")
    .foregroundStyle(.tint)
  
  Text("Hello")
    .foregroundStyle(.primary)
}
