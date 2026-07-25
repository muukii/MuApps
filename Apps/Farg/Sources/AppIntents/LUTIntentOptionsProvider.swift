//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AppIntents
import Foundation

/// Supplies the current LUT library as labeled String values in Shortcuts.
///
/// The parameter persists only `LUT.id`; the custom item presentation keeps
/// implementation identifiers out of the picker while avoiding an AppEntity
/// lifecycle for a value that never leaves this action.
nonisolated struct LUTIntentOptionsProvider: DynamicOptionsProvider {

  func results() async throws -> IntentItemCollection<String> {
    let items = await MainActor.run {
      LUTLibrary().luts.map { lut in
        IntentItem(
          lut.id,
          title: "\(lut.name)",
          subtitle: "\(lut.format == .cube ? "Cube" : "Image") • \(lut.dimension)³"
        )
      }
    }

    return IntentItemCollection(
      sections: [
        IntentItemSection(items: items),
      ]
    )
  }
}
