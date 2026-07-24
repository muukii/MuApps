# Brightroom Video Specification

## Overview

Brightroom Video is an iPhone and iPad video editor for applying color lookup
tables (LUTs) to a selected video. Preview and export evaluate the same
Brightroom parametric feature document.

## Video selection

- The empty state offers a **Choose Video** action backed by the system Photos
  picker.
- After selection, the video plays in the editor preview.
- The navigation bar provides **Change Video** while a video is loaded.

## LUT editing

- **Original** disables LUT processing.
- Bundled starter LUTs are available on first launch.
- The LUT library imports `.cube`, `.png`, `.jpg`, and `.jpeg` LUT files from
  Files and stores private copies in Application Support.
- Imported LUTs can be deleted from the LUT library.
- The intensity slider blends the selected LUT from 0% to 100%.

## Export

- **Export** renders the current parametric document to a QuickTime movie while
  preserving the source render extent and audio.
- The app displays progress and supports cancellation.
- On supported devices, export uses a continued-processing background task so
  it can continue after the app leaves the foreground.
- When continued processing is unavailable, export falls back to a foreground
  task and tells the user that the app must remain open.
- Completed exports are saved to the user's photo library when permission is
  granted and remain shareable from the completion screen.

## Rendering dependency

The application owns product UI, LUT-library persistence, Photos integration,
and export orchestration. LUT parsing, feature evaluation, and video
composition are provided by the `BrightroomParametric` product from the
Brightroom git submodule.
