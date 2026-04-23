//
//  TranscribeTip.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/19.
//

import TipKit

/// Tip to introduce users to the on-device transcription feature
struct TranscribeTip: Tip {
  var title: Text {
    Text("Transcribe Audio")
  }

  var message: Text? {
    Text("Generate subtitles from video audio using on-device speech recognition.")
  }

  var image: Image? {
    Image(systemName: "waveform.badge.mic")
  }
}
