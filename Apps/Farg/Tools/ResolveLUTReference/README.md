# Resolve LUT Reference Generator

This tool generates the immutable DaVinci Resolve oracle used by Färg's
Rec.709 LUT tests. Resolve is a regeneration dependency only; normal
`xcodebuild` tests read the committed TIFF and manifest and never launch
Resolve.

## Artifacts

The default paths intentionally sit beside the consuming test target:

```text
Apps/Farg/Tests/FargTests/Fixtures/ResolveLUTReference/
  rec709-full-range-source.tiff
  rec709-full-range-resolve-21.tiff
  rec709-full-range-resolve-21.manifest.json
  rec709-full-range-resolve-21.manifest.json.sha256
```

The production LUT defaults to:

```text
Apps/Farg/Resources/StarterLUTs/AppleLog1 Example.cube
```

The manifest records the SHA-256 and byte count of the source TIFF,
production LUT, Resolve output, generator, and embedded macOS ITU-709 ICC
profile. The `.sha256` sidecar hashes the exact manifest bytes.

## Generate the source without Resolve

Run this first while Resolve is closed:

```sh
/usr/bin/python3 \
  Apps/Farg/Tools/ResolveLUTReference/generate_reference.py \
  --generate-source-only
```

Pass `--overwrite` only when intentionally regenerating the committed source.
This mode imports neither the Resolve scripting library nor the Resolve app.

The source is an uncompressed, top-left-oriented, chunky RGB16 TIFF:

- 432×432 pixels
- 27×27 patches
- 16×16 pixels per patch
- nine channel levels: `[0, 8, 16, 24, 32, 40, 48, 56, 64] / 64`
- full-range unsigned 16-bit samples
- `/System/Library/ColorSync/Profiles/ITU-709.icc` embedded without changing
  sample values

For a patch at `(xPatch, yPatch)`:

```text
panelX   = blueIndex % 3
panelY   = blueIndex / 3
xPatch   = panelX * 9 + redIndex
yPatch   = panelY * 9 + greenIndex
```

Red increases left-to-right, green increases top-to-bottom, and blue
increases across the 3×3 panels in row-major order.

## Safe Resolve regeneration

The safest starting state is:

1. Finish and close every project in Resolve.
2. Quit Resolve completely.
3. In Resolve Preferences, allow local external scripting.
4. Ensure a fresh project defaults to the intended **3D Lookup Table
   Interpolation**. This setting is not exposed through Resolve 21's
   documented Project scripting settings.
5. Run:

```sh
/usr/bin/python3 \
  Apps/Farg/Tools/ResolveLUTReference/generate_reference.py \
  --launch-headless \
  --confirm-lut-interpolation Trilinear \
  --overwrite
```

`--launch-headless` uses Blackmagic Design's documented `-nogui` mode only
when no process named `Resolve` exists.

The tool connects to Resolve and immediately calls
`ProjectManager.GetCurrentProject()`. If Resolve restored a last-opened
project, or a GUI session already has a project open, the tool exits with
status `2` before it:

- stages a LUT,
- creates a project,
- creates or replaces golden output files.

It never closes or switches a user-owned project. If the tool started the
headless process and startup restored a project, it only quits that owned
process after the safety abort.

When Resolve is already running with no project open, omit
`--launch-headless`; the generator attaches to that process and leaves it
running afterward.

## Resolve reference contract

The generator creates one UUID-named temporary project and verifies every
accepted setting with `SetSetting` followed by `GetSetting`:

```text
Color science                   DaVinci YRGB
Automatic color management      Off
Separate color space and gamma  On
Timeline color space            Rec.709
Timeline gamma                  Gamma 2.4
Output color space              Rec.709
Output gamma                    Gamma 2.4
Color-space-aware grading       Off
Video data levels               Full
Timeline/frame rate             432×432 @ 30
```

The imported TIFF's clip Data Level is separately set to `Full` and
round-tripped. The production LUT is applied at amount 1.0 to Color node 1
using `Graph.SetLUT`; it is not installed as an input, output, or display LUT.

Resolve 21 does not document a scripting key for **3D Lookup Table
Interpolation**. The command therefore requires an explicit
`--confirm-lut-interpolation` declaration. If a future Resolve version exposes
that value in `Project.GetSetting()`, the generator verifies it and records
the API key/value. Otherwise the manifest marks the declaration as
caller-confirmed rather than API-verified.

## Cleanup guarantees

The LUT is staged under a content-addressed name:

```text
/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/
  FargGolden/<lut-sha-prefix>-<name>.cube
```

The generator removes it only when this invocation created it and its content
still has the expected hash. Pre-existing LUTs and non-empty directories are
preserved.

The temporary project is eligible for deletion only when its exact name
matches:

```text
Farg Resolve LUT Reference <UUID>
```

Final output and manifest files are published only after the temporary
project and staged LUT have been cleaned successfully. A cleanup failure is a
hard error and does not publish a new golden.

## Current isolation limit

Resolve's official scripting API attaches to the single running Resolve
process. No documented command-line option creates an isolated second
instance or a temporary Project Library. Therefore this tool deliberately
refuses to run alongside an open project. Use a separate macOS account or
dedicated machine if Resolve golden generation must run concurrently with
interactive Resolve work.
