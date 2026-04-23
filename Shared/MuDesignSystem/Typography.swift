import SwiftUI

public enum MuFonts {
  public static func largeTitle() -> Font {
    .system(.largeTitle, design: .rounded, weight: .bold)
  }

  public static func title() -> Font {
    .system(.title, design: .rounded, weight: .semibold)
  }

  public static func body() -> Font {
    .system(.body)
  }
}
