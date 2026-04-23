//
//  YouTubePlayerHTML.swift
//  YouTubeSubtitle
//
//  1st Party YouTube Player - HTML Template
//
//  YouTube iFrame Player API Reference:
//  https://developers.google.com/youtube/iframe_api_reference
//

import Foundation

// MARK: - YouTube iFrame Player API Specification
//
// ## Player State Values (getPlayerState)
// -1: unstarted  - Player has not started
//  0: ended      - Video has finished playing
//  1: playing    - Video is currently playing
//  2: paused     - Video is paused
//  3: buffering  - Video is buffering
//  5: cued       - Video is cued and ready to play
//
// ## Events
// - onReady: Player is ready to receive API calls
// - onStateChange: Player state has changed (event.data contains state value)
// - onError: An error occurred
//   - Error codes:
//     - 2: Invalid parameter
//     - 5: HTML5 player error
//     - 100: Video not found
//     - 101/150: Embedding not allowed
//
// ## Player Functions
// - playVideo(): Start playback
// - pauseVideo(): Pause playback
// - seekTo(seconds, allowSeekAhead): Seek to position
// - setPlaybackRate(rate): Set playback speed (0.25, 0.5, 1, 1.5, 2)
// - getCurrentTime(): Get current playback position in seconds
// - getDuration(): Get video duration in seconds
// - getPlayerState(): Get current state (-1, 0, 1, 2, 3, 5)
//
// ## Minimum Requirements
// - Minimum size: 200x200 pixels
// - Recommended: 480x270 pixels (16:9 aspect ratio)
//

enum YouTubePlayerHTML {

  /// Generate HTML for YouTube iFrame Player
  /// - Parameters:
  ///   - videoID: YouTube video ID
  ///   - autoplay: Whether to autoplay (default: false)
  ///   - controls: Show YouTube controls (default: true)
  ///   - origin: Origin URL for YouTube API (must match baseURL used in loadHTMLString)
  /// - Returns: HTML string
  static func generate(
    videoID: String,
    autoplay: Bool = false,
    controls: Bool = true,
    origin: String
  ) -> String {
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
      <style>
        * { margin: 0; padding: 0; }
        html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
        #player { width: 100%; height: 100%; }
      </style>
    </head>
    <body>
      <div id="player"></div>
      <script src="https://www.youtube.com/iframe_api"></script>
      <script>
        // YouTube iFrame Player API
        // State values: -1=unstarted, 0=ended, 1=playing, 2=paused, 3=buffering, 5=cued
        var player;
        var isReady = false;

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            videoId: '\(videoID)',
            width: '100%',
            height: '100%',
            playerVars: {
              autoplay: \(autoplay ? 1 : 0),
              controls: \(controls ? 1 : 0),
              playsinline: 1,
              rel: 0,
              modestbranding: 1,
              fs: 0,
              enablejsapi: 1,
              origin: '\(origin)'
            },
            events: {
              onReady: onPlayerReady,
              onStateChange: onPlayerStateChange,
              onError: onPlayerError
            }
          });
        }

        function onPlayerReady(event) {
          isReady = true;
          postMessage('ready', null);
        }

        function onPlayerStateChange(event) {
          // event.data: -1=unstarted, 0=ended, 1=playing, 2=paused, 3=buffering, 5=cued
          postMessage('stateChange', event.data);
        }

        function onPlayerError(event) {
          // Error codes: 2=invalid param, 5=HTML5 error, 100=not found, 101/150=embed blocked
          postMessage('error', event.data);
        }

        // Post message to Swift via WKScriptMessageHandler
        function postMessage(event, data) {
          try {
            webkit.messageHandlers.youtubePlayer.postMessage({
              event: event,
              data: data
            });
          } catch (e) {
            console.error('Failed to post message:', e);
          }
        }

        // API functions called from Swift via evaluateJavaScript
        function play() {
          if (isReady && player) player.playVideo();
        }

        function pause() {
          if (isReady && player) player.pauseVideo();
        }

        function mute() {
          if (isReady && player) player.mute();
        }

        function unmute() {
          if (isReady && player) player.unMute();
        }

        function seekTo(seconds) {
          if (isReady && player) player.seekTo(seconds, true);
        }

        function setPlaybackRate(rate) {
          if (isReady && player) player.setPlaybackRate(rate);
        }

        function getCurrentTime() {
          if (isReady && player) return player.getCurrentTime();
          return 0;
        }

        function getDuration() {
          if (isReady && player) return player.getDuration();
          return 0;
        }

        function getPlayerState() {
          if (isReady && player) return player.getPlayerState();
          return -1;
        }

        function getPlaybackRate() {
          if (isReady && player) return player.getPlaybackRate();
          return 1;
        }
      </script>
    </body>
    </html>
    """
  }
}
