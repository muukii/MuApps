import SwiftUI

extension View {
  
  /**
   TMP:
   This is going to be a utility extension that constraints its frame on platform.
   */
  public func frameAdaptive() -> some View {
    self
      .frame(maxWidth: 400)
      .frame(maxWidth: .infinity)
  }
  
}
