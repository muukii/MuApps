# Färg Specification

## Overview

Färg is an iPhone video editor for applying one color lookup table (LUT) recipe
to one or more videos. Preview and export evaluate the same Brightroom
parametric feature document and temporal recipe for every video in the
collection. Preview evaluates that recipe at a bounded pixel target derived
from the Editor window, while export preserves each source's display
resolution. The app uses its dedicated Färg icon and supports portrait
orientation only.
The visible app name remains **Färg**, while Spotlight can also find the app
when a person searches for **Farg** without the diacritic.

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
  copy-free video selection and export benefits. **Continue** then
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
- Settings includes a **Video Import** section where the user can choose or clear
  one default Files folder. Färg stores a security-scoped bookmark for that
  explicitly authorized directory, plus available volume metadata for display
  and diagnostics.
- The Home Files picker and Editor's **Add Videos > Files** picker start in the
  bookmarked directory when it can be resolved. If its external storage is not
  connected or access has been revoked, Files remains usable and opens at its
  normal system-selected location instead.
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
- `EditorView` exists only for a nonempty video collection. Its close control
  opens a contextual menu anchored to that control; choosing its destructive
  **Discard Edits** action returns to the inline media picker. Dismissing the
  menu keeps editing. Removing the last video also returns to the picker
  instead of displaying an empty editor state.
- Adding videos to an existing collection uses the trailing **Add Videos** cell
  in the filmstrip. It offers Photos and Files, keeps the current preview
  available, and reports each selected clip's queued or loading state in its
  filmstrip position.
- The **Videos** filmstrip identifies the current preview, lets the user switch
  among clips, and exposes **Delete Video** in each ready clip's context menu.
  Removing the last clip returns to the picker instead of showing an empty
  editor.
- The selected video plays in the editor preview. Exposure, LUT, motion-blur,
  and grain settings remain shared across the collection; changing the preview
  does not change the recipe.
- The preview uses Färg-owned playback controls instead of the system video
  player interface. Preview audio starts muted. The controls provide play/pause,
  mute/unmute, current time, duration, and a timeline for seeking while keeping
  the video surface available for future editor-specific controls.
- The video surface is centered and fitted to the selected movie's presentation
  aspect ratio. Any remaining letterbox area belongs to the neutral editor
  stage instead of enlarging the player layer beyond the movie.
- Live Preview resolves its processing ceiling from the Editor window content
  bounds multiplied by the current display scale, capping each dimension at
  1080 pixels. The display-oriented source is uniformly fitted to that pixel
  ceiling, never upscaled, and rounded down to hardware-compatible even
  dimensions.
- The first valid Editor-window measurement prepares immediately. That target
  remains locked for the selected clip: changing an effect tab can resize the
  visible player but cannot replace the custom compositor's render context. A
  later selected clip adopts the latest valid Editor-window target; a transient
  zero-size measurement never replaces it with a full-resolution fallback.
- Preview prepares one temporal source topology per selected movie. LUT and
  Motion Blur enablement changes replace only the video composition on the
  existing player item. Strength updates its live temporal parameter, while
  Exposure and Grain changes update the live parametric document. These edits
  do not seek or reset the current playback position.
- Preview audio mixes with music, podcasts, or other audio already playing
  outside Färg instead of interrupting it.
- The editor navigation bar places its close menu and **Settings** at the
  leading edge as separate Liquid Glass groups. The selected video's
  **Information** action and **Export** sit at the trailing edge as separate
  groups. Export remains disabled while an additional video selection is loading.
- **Information** presents the selected video's name and source category, then
  lazily reads duration, display-oriented resolution, nominal frame rate, codec,
  estimated video bitrate, dynamic range, color primaries, transfer function,
  and YCbCr matrix. It does not expose a Files path or Photos identifier.
- A collection containing one video uses the same editing model and layout as
  a larger batch.
- The editing surface follows the system Light or Dark appearance and uses
  semantic background, primary, and secondary styles to express hierarchy.
  The video stage remains neutral black around the fitted movie.
- In compact layouts, editing controls sit below the video. On wider portrait
  layouts, the controls move to a trailing inspector beside the video.
- The editor orders its regions as video player, **Videos** filmstrip, then
  editing controls. **Videos** stays outside the editing controls' vertical
  scroll view while its own filmstrip remains horizontally scrollable.
- Below **Videos**, a fixed bottom tab bar switches the editing controls among
  **LUT**, **Exposure**, **Motion Blur**, and **Grain**. Switching tabs does not
  change the current video or recipe. The editor reserves the bar's measured
  height as a bottom inset, and the complete inset footprint prevents touches
  from reaching the scrolling controls underneath it.

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
  blur and grain disabled. An earlier interactive edit cannot leak its
  temporal or grain settings into a Shortcut request.
- On iOS 26, background App Intent runtime is system-bounded, so sufficiently
  long renders may be cancelled. The action's rendering boundary is prepared
  to adopt iOS 27 long-running intent execution when that SDK is used.

## LUT editing

- **Original** disables LUT processing.
- Färg currently supports LUTs whose final output is display-referred SDR
  Rec.709. Because supported LUT file formats do not provide a reliable
  standardized output-color-space declaration, every imported and bundled LUT
  is interpreted under that contract; LUTs authored for another output color
  space are not supported.
- Färg treats the authored Rec.709 result as a Gamma 2.4 mastering intent, then
  materializes Preview, LUT thumbnails, and Export through Core Media's Rec.709
  delivery color space. This compensates the final pixel values for standard
  Apple 1-1-1 playback without adding an Apple Log-specific processing branch
  or changing the LUT's source-input contract.
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
- In the editor's LUT selector, linked folders appear as navigable folder items
  alongside **No LUT** and individually imported LUTs. Opening a folder shows
  its direct LUTs and child folders, rebuilding the open level from the latest
  synchronized hierarchy when its contents change. The selector's Back control
  returns to the parent directory without flattening the Files hierarchy.
- The editor keeps the currently selected LUT visible when the selection
  changes, including selections supplied by Shortcuts or linked folders.
- Unlinking a folder stops future synchronization but preserves its current LUT
  copies as regular imported LUTs.
- LUTs imported individually from Files can be deleted from the LUT library.
  Linked LUTs are managed by changing their source folder.
- The editor applies the selected LUT at full intensity. It does not currently
  expose an intensity control.
- The **LUT** tab contains the **No LUT** choice and the preview-backed LUT
  selector.
- Every LUT choice in the editor includes a still preview. Färg captures the
  source video's first frame on load and refreshes that still when playback
  stops or a paused scrub settles. It does not evaluate every LUT continuously
  while the video is playing.
- Settings includes a built-in color test and lets the user add multiple sample
  images from Photos. Each custom sample is copied into Application Support,
  normalized to a bounded JPEG, and given a required user-authored label such
  as a camera or Log profile.
- Settings presents preview samples in a horizontally scrolling strip. Scrolling
  only browses the strip; tapping a sample selects it as the common input for
  the LUT previews below. An Add Sample tile stays at the trailing end, while
  each custom sample exposes Rename and Delete through its context menu.
- The active Settings sample is applied to every LUT under identical input
  conditions. Each LUT row shows only the rendered result at the same aspect
  ratio as the source preview. Custom sample labels can be renamed and their
  app-owned copies can be deleted without changing the LUT library.

## Exposure

- Exposure is a shared part of the current video collection's recipe. Its
  control appears in the dedicated **Exposure** tab and is authored in EV.
- The slider covers -2.0 through +2.0 EV in 0.1 EV increments. New sessions
  start at 0.0 EV, and **Reset** returns the adjustment to 0.0 EV.
- Exposure is applied after optional Optical Flow motion blur and before the
  selected LUT. It therefore changes the LUT's input and color response rather
  than only brightening the final display-referred result.
- Exposure changes update the live Brightroom parametric document without
  replacing the Preview composition, player item, or playhead.
- Editor LUT stills apply the current Exposure before every LUT. The **No LUT**
  still applies Exposure without adding a LUT, so every visible choice matches
  the same authored input conditions. Obsolete still results are discarded,
  and a short debounce prevents slider ticks from starting redundant work.
- Preview and export evaluate the same Exposure node in the same feature order.

## Optical Flow motion blur

- Motion blur is an optional shared part of the current video collection's
  recipe. Its enable switch and Strength control appear in the dedicated
  **Motion Blur** tab.
- Färg prepares previous, current, and next source frames and sends them to the
  iOS 26 VideoToolbox motion-blur processor with internal Optical Flow
  calculation enabled. It does not substitute a simple frame blend.
- Motion-blur rendering samples those frames at equal temporal offsets and
  normalizes variable-frame-rate input to its nominal fixed cadence. This keeps
  the timestamps supplied to Optical Flow truthful; the movie duration and
  copied audio timing do not change.
- Motion blur is applied before the Brightroom parametric LUT, matching the
  ordering of an in-camera exposure followed by color processing.
- Decoded source color is preserved through the temporal stage. When a LUT is
  selected, only the post-LUT image is rendered and tagged as Rec.709; the
  composition must not convert an Apple Log or wide-gamut source to Rec.709
  before the LUT evaluates it.
- Preview and export use the same temporal samples, ordering, and `Strength`
  value. Preview runs Optical Flow at its Editor-window-fitted working
  resolution; export runs at the source display resolution. `Strength` follows
  VideoToolbox's 1–100 range; Färg does not present it as a shutter angle
  because Apple defines no physical angle conversion.
- Disabled Motion Blur is Preview's semantic strength zero: it keeps the
  prepared temporal source but requests only the current track, bypassing
  VideoToolbox and its previous/next working buffers. Literal zero is never
  passed to VideoToolbox because its documented range begins at one. Export
  uses the same custom-compositor current-frame path when Motion Blur is
  disabled so its color processing does not change with the enable switch.
- Realtime preview bounds temporal work to one rendering frame and the newest
  queued frame. If Optical Flow cannot match playback cadence, an obsolete
  queued preview frame is cancelled instead of retaining its three decoded
  source frames indefinitely. Offline export never drops a requested frame.
- Encoded source size, display-oriented size, VideoToolbox working size, and
  composition output size are separate geometry contracts. Metadata-rotated
  portrait movies and physically portrait-encoded movies therefore produce the
  same upright Preview without treating display width and processor width as
  interchangeable.
- When Editor-window fitting or portrait canonicalization is required, Preview
  transforms all three temporal source buffers into bounded, IOSurface-backed
  pools before Optical Flow. A source-sized buffer that already matches the
  processor geometry is passed through directly. Pool allocation is capped and
  the VideoToolbox session plus both pools are flushed when the render context,
  source, target, or owner changes.
- The effect is available only when
  `VTMotionBlurConfiguration.isSupported` is true. Simulator shows the control
  as unavailable, and a preparation failure is reported rather than silently
  exporting without the effect.
- VideoToolbox accepts a working frame up to 4096×2160 on iOS. Preview checks
  this limit after viewport downsampling. A source-resolution physical portrait
  export such as 2160×3840 is rotated only inside the processor to 3840×2160
  and restored to 2160×3840 for output. A working frame that does not fit the
  limit in either orientation fails with an explicit message.
- LUT still thumbnails remain single-frame previews and do not attempt to
  display motion blur.

## Film grain

- Grain is an optional shared part of the current video collection's recipe.
  Its enable switch and the **Intensity** and **Size** controls appear in the
  dedicated **Grain** tab.
- Grain is rendered by a custom Metal Core Image kernel from deterministic
  band-limited value noise, producing round organic clumps rather than
  per-pixel digital noise. Each output frame samples a different noise region
  derived from its frame time, so the texture animates during playback while
  the same frame time renders identical grain in preview and export.
- The grain follows a negative-film luminance response: it peaks just below
  middle gray, rolls off through the toe and shoulder, and leaves pure black
  and pure white clean. It is composited additively in gamma-encoded space and
  carries a subtle per-channel decorrelation so color footage shows organic
  dye-layer texture instead of purely monochrome speckle.
- Grain is applied after the Brightroom parametric LUT, modeling a post-grade
  film-emulation stage; Optical Flow motion blur, when enabled, runs before
  both.
- Grain is a Färg-owned Brightroom parametric feature. Its authored parameters
  live in the same ordered editing document as the LUT, while the current
  frame's presentation time arrives separately as a render-time input.
- **Intensity** (1–100) controls the grain contrast. **Size** (1–100) controls
  the grain pitch relative to the output height, so the viewport-fitted
  preview and the source-resolution export show the same texture scale.
- Grain has no device-support requirement and remains available in Simulator.
  It does not change export background eligibility; only Motion Blur restricts
  an export to the foreground.
- LUT still thumbnails remain single-frame previews and do not attempt to
  display grain.

## Export

- The top-right **Export** action snapshots the shared parametric and
  motion-blur recipe and renders every video in picker order. Each input becomes
  a separate HEVC QuickTime movie; batch export never joins videos together.
- Every output uses its own source video's render resolution and average video
  bitrate as the encoder target. Audio tracks are preserved. LUT-only exports
  preserve source frame timing; motion-blur exports use the nominal fixed
  cadence described above. Because HEVC bitrate is an average target, a
  completed file's measured bitrate can vary slightly with its content.
- An export with a selected LUT carries Rec.709 primaries, transfer, and matrix
  metadata from the video-composition output through the asset reader and HEVC
  writer as NCLC 1-1-1. The output contract is determined by the LUT rather than
  copied from the source movie; the Core Media delivery transform changes the
  materialized pixel values, not these tags.
- Before a rendered video sample reaches the HEVC writer, its format dimensions
  must exactly match the composition's source-resolution encoder dimensions.
  A portrait geometry mismatch fails at this boundary with expected and actual
  sizes instead of surfacing later as an opaque writer failure.
- Before export, the editor identifies the number of separate outputs and warns
  how many HDR inputs will be rendered to SDR.
- The export sheet keeps every video in a picker-ordered list from start to
  finish. Each stable row reports its own waiting, rendering, Photos-saving,
  exported, failed, cancelling, or cancelled state and exposes the actions
  appropriate to that video. A compact header retains aggregate progress.
- Actual video rendering is admitted through one process-wide resource gate.
  Its current capacity is one, so encoding remains serial and bounds peak GPU
  and memory use. The job and UI model do not depend on that value, allowing a
  measured future policy to admit more than one render without restructuring
  export sessions.
- The foreground **Export** action registers and submits every
  background-eligible per-video continued-processing request before starting
  app-owned work or presenting the sheet. Work never waits for a background-task
  launch handler. An independent, picker-ordered app scheduler admits renders up
  to the resource-gate capacity.
- Starting export detaches the editor's player item and Optical Flow session so
  preview and export do not own two VideoToolbox pipelines simultaneously. The
  preview is rebuilt at the preserved playhead after the export sheet closes.
- Each active row can be cancelled independently. **Cancel All** sends
  cancellation to every pending or active attempt before waiting for in-flight
  readers and Optical Flow frames to drain. Rows remain visible as
  **Cancelling** until that drain completes and then become retryable.
- A render failure is recorded for that video without preventing later videos
  from being attempted. The same row then supports Retry; successful rows
  support Share and preserve their output while a failed or cancelled sibling
  is retried. Retry keeps the row identity but creates a new attempt identity.
- Failure to save a completed render to Photos is distinct from render failure;
  the shareable movie remains available and can be saved again.
- A movie is not eligible for Photos import until both the transferred video
  samples and the finalized output track reach the source video's intended end.
  An orderly early video EOF is treated as render failure instead of producing
  a movie that holds its final frame while audio continues.
- Every background-eligible video attempt receives a unique
  continued-processing task identifier under `app.muukii.farg.export.*`. The
  task owns that video's system runtime, progress, expiration, and completion,
  but it does not decide render concurrency. Its launch handler attaches to the
  already-running attempt and replays current progress; it never starts the
  render. Retrying a row creates a new attempt identifier, which is registered
  and submitted from the foreground Retry action before it enters the app
  scheduler.
- LUT-only attempts are eligible for continued processing. On devices that
  advertise background GPU support, their requests ask for the GPU; otherwise
  they use default resources. The task reports truthful queue-admission progress
  from 0–5% based on all predecessor renders, its own render from 5–99%, and
  Photos import from 99–100%. Waiting subtitles identify the number of earlier
  videos rather than implying simultaneous encoding. App rows update at
  whole-percent resolution. Progress reporting does not prevent the system from
  expiring a task when conditions change.
- Motion Blur requires GPU-backed Optical Flow and is foreground-only. Färg does
  not submit a continued-processing request for an attempt whose recipe includes
  Motion Blur, even when the device advertises background GPU support. The export
  sheet shows a red **Keep Färg open** notice while any such attempt remains
  unsettled. Leaving Färg does not provide a supported pause, resume, or automatic
  cancellation boundary, so completion and output after leaving the foreground
  are not guaranteed.
- When one continued-processing request cannot be registered or submitted, only
  that video falls back to foreground execution. The header reports how many
  videos require Färg to remain open and includes the system scheduling error.
  This also provides a per-item fallback if a large selection exceeds the
  system's pending-request allowance; background continuation is not guaranteed
  for an unbounded number of videos.
- System expiration or system cancellation stops only the corresponding video.
  Explicit item or session cancellation remains authoritative while Photos is
  saving, so a cancelled attempt cannot later report successful completion.
- Completed exports are saved to the user's photo library when permission is
  granted and remain shareable from their stable list rows.

## Rendering dependency

The application owns product UI, LUT-library persistence, Photos integration,
and export orchestration. LUT parsing, the ordered single-frame feature graph,
and explicit presentation-time propagation are provided by the
`BrightroomParametric` product from the Brightroom git submodule. Färg's sibling
`FargMotionBlur` framework owns temporal-neighbor composition and the
VideoToolbox Optical Flow processor; the app-level render pipeline combines
both modules in one preview/export pass. Film grain is a Färg-owned host-defined
parametric feature evaluated after the LUT; its stitchable Metal Core Image
kernel is compiled into the app's ordinary `default.metallib`.
