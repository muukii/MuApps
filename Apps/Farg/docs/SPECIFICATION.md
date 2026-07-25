# Färg Specification

## Overview

Färg is an iPhone video editor for applying one color lookup table (LUT) recipe
to one or more videos. Preview and export evaluate the same Brightroom
parametric feature document for every video in the collection. The app uses its
dedicated Färg icon and supports portrait orientation only.

## Privacy

- Färg does not collect or transmit personal data. It has no account system,
  developer-operated server, analytics, advertising, or tracking.
- Videos and LUTs explicitly selected through Photos, Files, or Shortcuts are
  processed on device. Photos and Files source movies are not copied into
  Färg's container; app-owned Shortcut inputs and rendered outputs remain
  inside the local app container or cache.
- The Settings screen's **Privacy Policy** row opens the published policy in
  the system browser.

## Onboarding

- On first launch, Färg first introduces LUT-based single and batch editing
  with its large logo and a compact **Start** Liquid Glass capsule. This stage
  does not request system access.
- The welcome stage summarizes the complete workflow: applying user LUTs to one
  clip or a batch; opening videos from Photos, Files, or an external volume;
  continued-processing background export when system scheduling is available;
  Optical Flow motion blur on supported devices for adding smoother motion
  trails to footage captured without an ND filter; and a single-video Shortcuts
  action that applies a selected LUT and passes its rendered movie to the next
  workflow action.
- The second screen prepares the person for Photos access and explains its
  copy-free video selection and export benefits. **Allow Photos Access** then
  requests Photo Library read/write authorization. Full and Limited access both
  allow onboarding to complete; the system result is not a requirement to
  enter the app.
- Each stage's primary action is a compact, centered 240 by 44 point Liquid
  Glass capsule rather than a full-width bottom command bar.
- Dismissing the system request with **Don't Allow** still enters the app. The
  Files picker remains fully usable, and selecting a Photos video later
  requests the same access before Färg opens its PhotoKit-backed source.
- Completing onboarding is stored only on the device, so subsequent launches
  open directly on the media-selection home.

## Video selection

- Färg opens on an inline system Photos picker filtered to videos, so the media
  library is immediately available without first opening a separate picker
  presentation. Its trailing navigation-bar action opens the system Files picker
  for one or more movies, including movies stored on a connected external
  volume. The home navigation bar has no title; Settings remains available from
  its leading action. The Photos picker retains its top accessory for system
  search and album switching.
- The inline picker uses continuous ordered multi-selection. After selecting one
  or more videos, the user explicitly starts a new editing session from the
  floating bottom action.
- Photos movies are opened as PhotoKit-provided `AVAsset` instances instead of
  being exported into Färg's container. This requires Photos read access; under
  Limited Photos access, only assets included in the app's allowed selection
  can be opened without copying.
- Files movies remain at their selected URLs. Färg holds their security-scoped
  access for the complete edit and export lifetime, allowing an external-drive
  movie to be previewed and rendered without first duplicating it on the
  iPhone. Disconnecting or otherwise making the source unavailable causes
  preview or export to fail rather than silently creating a private copy.
- Färg resolves selected sources sequentially and preserves picker order in the
  editor. During this initial work, a blocking HUD temporarily overlays the
  picker and remains visible for at least one second so the state change is
  perceptible. Its presentation and dismissal use a snappy opacity transition
  only; the HUD does not move or resize. Its **Cancel** action stops source
  resolution and restores the picker without discarding the current Photos
  selection. The editor opens in a full-screen cover only after at least one
  selected movie is ready.
- `EditorView` exists only for a nonempty video collection. Its close action
  asks whether to discard the current video selection and adjustments; choosing
  **Discard Edits** returns to the inline media picker. Removing the last video
  also returns to the picker instead of displaying an empty editor state.
- Adding videos to an existing collection uses the trailing **Add Videos** cell
  in the filmstrip. It offers Photos and Files, keeps the current preview
  available, and reports each selected clip's queued or loading state in its
  filmstrip position.
- The **Videos** filmstrip identifies the current preview, lets the user switch
  among clips, and exposes **Delete Video** in each ready clip's context menu.
  Removing the last clip returns to the picker instead of showing an empty
  editor.
- The selected video plays in the editor preview. LUT and intensity remain
  shared across the collection; changing the preview does not change the
  recipe.
- The preview uses Färg-owned playback controls instead of the system video
  player interface. It provides play/pause, current time, duration, and a
  timeline for seeking while keeping the video surface available for future
  editor-specific controls.
- The video surface is centered and fitted to the selected movie's presentation
  aspect ratio. Any remaining letterbox area belongs to the neutral editor
  stage instead of enlarging the player layer beyond the movie.
- Preview audio mixes with music, podcasts, or other audio already playing
  outside Färg instead of interrupting it.
- The editor navigation bar places its close action and **Settings** at the
  leading edge, and **Export** at the trailing edge. Export remains disabled
  while an additional video selection is loading.
- A collection containing one video uses the same editing model and layout as
  a larger batch.
- The editing surface uses neutral dark chrome in both system appearances so
  the video remains the only source of color.
- In compact layouts, editing controls sit below the video. On wider portrait
  layouts, the controls move to a trailing inspector beside the video.

## Shortcuts

- The **Open Video with LUT** action accepts a movie from a previous Shortcuts
  action and a LUT from the current Färg library.
- Running the action opens Färg and displays the movie in the
  editor with the selected LUT at 100% intensity.
- The action copies the supplied movie into app-owned cache storage before the
  temporary Shortcuts representation expires.
- A shortcut configured to receive movies in the share sheet can provide a
  Photos-to-Färg entry point.
- The **Apply LUT to Video** action runs without presenting the app UI, renders
  the supplied movie with the selected LUT at 100% intensity, and returns a
  QuickTime movie to the next Shortcuts action.
- Both Shortcuts actions remain LUT-specific and explicitly start with motion
  blur disabled. An earlier interactive edit cannot leak its temporal settings
  into a Shortcut request.
- On iOS 26, background App Intent runtime is system-bounded, so sufficiently
  long renders may be cancelled. The action's rendering boundary is prepared
  to adopt iOS 27 long-running intent execution when that SDK is used.

## LUT editing

- **Original** disables LUT processing.
- Färg installs **AppleLog1 Example** from its app bundle into the private LUT
  library on launch when that initial LUT record or stored copy is absent.
  The starter LUT uses the same validation and Application Support storage as
  Files-imported LUTs, so preview and export never render directly from the
  app bundle.
- Users can add further LUTs by importing individual files or linking a folder
  from Files.
- The LUT library imports `.cube`, `.png`, `.jpg`, and `.jpeg` LUT files from
  Files and stores private copies in Application Support.
- LUT display names use the source file name without its extension. Embedded
  `.cube` `TITLE` metadata is not used because authoring tools commonly write
  the same generic title into multiple LUT files.
- The LUT library can link a Files folder selected by the user. Färg remembers
  the authorized folder, scans it recursively while the app is
  active, and detects supported LUTs added, updated, or removed below it.
- Linked-folder changes are synchronized automatically. Added and updated LUTs
  are validated before Färg replaces the app-owned copies used for
  preview and export; removing a source LUT removes only its synchronized copy.
- While a large folder is synchronizing, its row reports the active phase and
  completed file count instead of remaining at an indeterminate waiting state.
- Linked LUTs preserve their Files directory hierarchy in the LUT library and
  identify their linked folder path in the editor's preview-backed selector.
  Directories without supported LUTs are not shown in Settings.
- The editor keeps the currently selected LUT visible when the selection
  changes, including selections supplied by Shortcuts or linked folders.
- Unlinking a folder stops future synchronization but preserves its current LUT
  copies as regular imported LUTs.
- LUTs imported individually from Files can be deleted from the LUT library.
  Linked LUTs are managed by changing their source folder.
- The intensity slider blends the selected LUT from 0% to 100%.
- The editor labels the **Look** and **Intensity** controls. When **Original**
  is selected, it reports that intensity is not applied instead of displaying
  an inactive percentage.
- Every LUT choice in the editor includes a still preview. Färg captures the
  source video's first frame on load and refreshes that still when playback
  stops or a paused scrub settles. It does not evaluate every LUT continuously
  while the video is playing.
- Settings includes a built-in color test and lets the user add multiple sample
  images from Photos. Each custom sample is copied into Application Support,
  normalized to a bounded JPEG, and given a required user-authored label such
  as a camera or Log profile.
- The active Settings sample is applied to every LUT under identical input
  conditions. Each LUT row shows the labeled source and rendered result side by
  side. Custom sample labels can be renamed and their app-owned copies can be
  deleted without changing the LUT library.

## Optical Flow motion blur

- Motion blur is an optional shared part of the current video collection's
  recipe. It appears in the editor inspector after LUT intensity and before the
  export summary.
- Färg prepares previous, current, and next source frames and sends them to the
  iOS 26 VideoToolbox motion-blur processor with internal Optical Flow
  calculation enabled. It does not substitute a simple frame blend.
- Motion-blur rendering samples those frames at equal temporal offsets and
  normalizes variable-frame-rate input to its nominal fixed cadence. This keeps
  the timestamps supplied to Optical Flow truthful; the movie duration and
  copied audio timing do not change.
- Motion blur is applied before the Brightroom parametric LUT, matching the
  ordering of an in-camera exposure followed by color processing.
- Preview and export use the same temporal composition and the same `Strength`
  value. `Strength` follows VideoToolbox's 1–100 range; Färg does not present it
  as a shutter angle because Apple defines no physical angle conversion.
- Realtime preview bounds temporal work to one rendering frame and the newest
  queued frame. If Optical Flow cannot match playback cadence, an obsolete
  queued preview frame is cancelled instead of retaining its three decoded
  source frames indefinitely. Offline export never drops a requested frame.
- The effect is available only when
  `VTMotionBlurConfiguration.isSupported` is true. Simulator shows the control
  as unavailable, and a preparation failure is reported rather than silently
  exporting without the effect.
- VideoToolbox accepts raw source frames up to 4096×2160 on iOS. Inputs above
  that limit fail with an explicit message instead of being downscaled
  implicitly.
- LUT still thumbnails remain single-frame comparisons and do not attempt to
  display motion blur.

## Export

- The top-right **Export** action snapshots the shared LUT and motion-blur
  recipe and renders every video in picker order. Each input becomes a separate
  HEVC QuickTime movie; batch export never joins videos together.
- Every output uses its own source video's render resolution and average video
  bitrate as the encoder target. Audio tracks are preserved. LUT-only exports
  preserve source frame timing; motion-blur exports use the nominal fixed
  cadence described above. Because HEVC bitrate is an average target, a
  completed file's measured bitrate can vary slightly with its content.
- Before export, the editor identifies the number of separate outputs and warns
  how many HDR inputs will be rendered to SDR.
- The app renders videos serially, displays both **Video X of N** and aggregate
  progress, and supports cancellation. Serial rendering bounds peak GPU and
  memory use for large collections.
- Starting export detaches the editor's player item and Optical Flow session so
  preview and export do not own two VideoToolbox pipelines simultaneously. The
  preview is rebuilt at the preserved playhead after the export sheet closes.
- Cancelling export keeps the progress sheet presented until the in-flight
  reader and Optical Flow frame have drained. Preview reconstruction starts
  only after those media resources are released.
- A render failure is recorded for that video without preventing later videos
  from being attempted. The completion screen lists per-video outcomes,
  supports sharing or saving each successful output, and can retry only render
  failures.
- Failure to save a completed render to Photos is distinct from render failure;
  the shareable movie remains available and can be saved again.
- A movie is not eligible for Photos import until both the transferred video
  samples and the finalized output track reach the source video's intended end.
  An orderly early video EOF is treated as render failure instead of producing
  a movie that holds its final frame while audio continues.
- One continued-processing background task owns the complete serial batch so it
  can continue after the app leaves the foreground. On devices that advertise
  background GPU support, the task requests the GPU; otherwise, it is submitted
  with default resources. The task reports fine-grained sample progress to the
  system while keeping visible UI updates percent-based. Each item's final
  percentage remains pending until its Photos import completes.
- When continued processing request submission fails, export falls back to a
  foreground task, shows the system error domain and code, and tells the user
  that the app must remain open.
- System expiration and explicit cancellation remain authoritative while Photos
  is saving; a cancelled batch cannot later report successful completion.
- Completed exports are saved to the user's photo library when permission is
  granted and remain shareable from the completion screen.

## Rendering dependency

The application owns product UI, LUT-library persistence, Photos integration,
and export orchestration. LUT parsing and single-frame feature evaluation are
provided by the `BrightroomParametric` product from the Brightroom git
submodule. Färg's sibling `FargMotionBlur` framework owns temporal-neighbor
composition and the VideoToolbox Optical Flow processor; the app-level render
pipeline combines both modules in one preview/export pass.
