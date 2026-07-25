//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Neutral colors shared by the editor stage and its controls.
///
/// The chrome intentionally avoids a colored accent so the video remains the
/// only source of color while the user evaluates a LUT.
struct EditorPalette {

  static let stage = Color.black
  static let chrome = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)
  static let raised = Color(red: 23 / 255, green: 23 / 255, blue: 25 / 255)
  static let hairline = Color(red: 44 / 255, green: 44 / 255, blue: 47 / 255)
  static let primary = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
  static let secondary = Color(red: 146 / 255, green: 146 / 255, blue: 152 / 255)

  private init() {}
}
