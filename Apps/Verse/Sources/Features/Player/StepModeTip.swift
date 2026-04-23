//
//  StepModeTip.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/25.
//

import TipKit

/// Tip to introduce users to the Step Mode feature accessible via long press
struct StepModeTip: Tip {
  var title: Text {
    Text("Step Mode")
  }

  var message: Text? {
    Text("Long press to switch to Step Mode for precise subtitle navigation.")
  }

  var image: Image? {
    Image(systemName: "play")
  }
}
