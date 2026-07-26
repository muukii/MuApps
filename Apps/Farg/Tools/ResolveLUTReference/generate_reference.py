#!/usr/bin/env python3
"""Generate Färg's Rec.709 LUT reference image with DaVinci Resolve.

The generator is intentionally separate from XCTest. It produces a committed
golden TIFF and a provenance manifest that XCTest can consume without requiring
DaVinci Resolve on the test machine.

Safety is fail-closed:

* If Resolve already has a current project, the tool aborts before staging a
  LUT, creating a project, or replacing reference artifacts.
* The Resolve project name contains a fresh UUID and only that exact name is
  eligible for cleanup.
* A LUT staged by an earlier process is never removed by this process.
* Final artifacts are published only after the temporary Resolve project and
  the LUT staged by this run have both been removed successfully.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple
import uuid


SCRIPT_PATH = Path(__file__).resolve()
REPOSITORY_ROOT = SCRIPT_PATH.parents[4]

DEFAULT_SOURCE_PATH = (
    REPOSITORY_ROOT
    / "Apps/Farg/Tests/FargTests/Fixtures/ResolveLUTReference"
    / "rec709-full-range-source.tiff"
)
DEFAULT_LUT_PATH = (
    REPOSITORY_ROOT
    / "Apps/Farg/Resources/StarterLUTs/AppleLog1 Example.cube"
)
DEFAULT_OUTPUT_PATH = (
    REPOSITORY_ROOT
    / "Apps/Farg/Tests/FargTests/Fixtures/ResolveLUTReference"
    / "rec709-full-range-resolve-21.tiff"
)
DEFAULT_MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "Apps/Farg/Tests/FargTests/Fixtures/ResolveLUTReference"
    / "rec709-full-range-resolve-21.manifest.json"
)

DEFAULT_RESOLVE_BINARY = Path(
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/MacOS/Resolve"
)
DEFAULT_RESOLVE_MODULES = Path(
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve"
    "/Developer/Scripting/Modules"
)
DEFAULT_RESOLVE_SCRIPT_LIBRARY = Path(
    "/Applications/DaVinci Resolve/DaVinci Resolve.app"
    "/Contents/Libraries/Fusion/fusionscript.so"
)
DEFAULT_RESOLVE_LUT_ROOT = Path(
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"
)
DEFAULT_REC709_ICC_PROFILE = Path(
    "/System/Library/ColorSync/Profiles/ITU-709.icc"
)

CHART_WIDTH = 432
CHART_HEIGHT = 432
PATCH_SIZE = 16
PATCHES_PER_AXIS = 27
LEVEL_COUNT = 9
LEVEL_NUMERATORS = tuple(range(0, 65, 8))
BLUE_PANEL_SIZE = 9
BLUE_PANEL_COUNT_PER_AXIS = 3

TEMP_PROJECT_PREFIX = "Farg Resolve LUT Reference "
STAGED_LUT_FOLDER_NAME = "FargGolden"
MANIFEST_SCHEMA_VERSION = 1


class ReferenceGenerationError(RuntimeError):
    """An expected failure that should stop reference generation."""


class ResolveSafetyAbort(ReferenceGenerationError):
    """A safety precondition failed before Resolve content was changed."""


@dataclass(frozen=True)
class FileDigest:
    """The SHA-256 identity and size of one file."""

    sha256: str
    byte_count: int


@dataclass
class ResolveConnection:
    """A Resolve scripting connection and optional process owned by this tool."""

    resolve: Any
    launched_process: Optional[subprocess.Popen]
    launched_by_tool: bool
    has_been_stopped: bool = False


@dataclass
class StagedLUT:
    """A LUT made discoverable to Resolve for this generation run."""

    absolute_path: Path
    resolve_relative_path: str
    created_by_tool: bool
    directory_created_by_tool: bool
    expected_sha256: str


@dataclass(frozen=True)
class ArtifactPaths:
    """Source, output, and manifest locations used by one generation run."""

    source: Path
    lut: Path
    output: Path
    manifest: Path

    @property
    def manifest_checksum(self) -> Path:
        """The sidecar containing the hash of the exact manifest bytes."""

        return Path(str(self.manifest) + ".sha256")


def _sha256(path: Path) -> FileDigest:
    """Return a streaming SHA-256 digest for ``path``."""

    digest = hashlib.sha256()
    byte_count = 0
    with path.open("rb") as file:
        while True:
            chunk = file.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            byte_count += len(chunk)
    return FileDigest(digest.hexdigest(), byte_count)


def _display_path(path: Path) -> str:
    """Return a repository-relative path when possible."""

    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPOSITORY_ROOT))
    except ValueError:
        return str(resolved)


def _align(value: int, alignment: int = 4) -> int:
    """Round ``value`` up to ``alignment`` bytes."""

    return (value + alignment - 1) // alignment * alignment


def _uint16_level(level_index: int) -> int:
    """Map one of nine chart levels to a rounded unsigned 16-bit sample."""

    if not 0 <= level_index < LEVEL_COUNT:
        raise ValueError("level_index must be in 0...8")
    numerator = LEVEL_NUMERATORS[level_index]
    return (numerator * 65535 + 32) // 64


def _make_chart_pixel_bytes() -> bytes:
    """Build the top-left-oriented 9×9×9 full-range RGB patch chart."""

    rows: List[bytes] = []
    for patch_y in range(PATCHES_PER_AXIS):
        panel_y = patch_y // BLUE_PANEL_SIZE
        green_index = patch_y % BLUE_PANEL_SIZE
        row = bytearray()
        for patch_x in range(PATCHES_PER_AXIS):
            panel_x = patch_x // BLUE_PANEL_SIZE
            blue_index = panel_y * BLUE_PANEL_COUNT_PER_AXIS + panel_x
            red_index = patch_x % BLUE_PANEL_SIZE
            pixel = struct.pack(
                "<HHH",
                _uint16_level(red_index),
                _uint16_level(green_index),
                _uint16_level(blue_index),
            )
            row.extend(pixel * PATCH_SIZE)
        encoded_row = bytes(row)
        rows.extend([encoded_row] * PATCH_SIZE)

    pixels = b"".join(rows)
    expected_size = CHART_WIDTH * CHART_HEIGHT * 3 * 2
    if len(pixels) != expected_size:
        raise AssertionError(
            f"Internal chart size mismatch: {len(pixels)} != {expected_size}"
        )
    return pixels


def _make_rec709_tiff(icc_profile: bytes) -> bytes:
    """Encode an uncompressed chunky RGB16 TIFF with an embedded Rec.709 ICC."""

    # TIFF field types used below.
    type_byte = 1
    type_ascii = 2
    type_short = 3
    type_long = 4
    type_rational = 5
    type_undefined = 7
    type_sizes = {
        type_byte: 1,
        type_ascii: 1,
        type_short: 2,
        type_long: 4,
        type_rational: 8,
        type_undefined: 1,
    }

    bits_per_sample = struct.pack("<HHH", 16, 16, 16)
    sample_format = struct.pack("<HHH", 1, 1, 1)
    x_resolution = struct.pack("<II", 72, 1)
    y_resolution = struct.pack("<II", 72, 1)
    software = b"Farg Resolve LUT Reference Generator\x00"
    pixel_bytes = _make_chart_pixel_bytes()

    # A value is either an integer stored directly in the four-byte IFD value
    # field or raw bytes placed in the out-of-line data area.
    entries: List[Tuple[int, int, int, Any]] = [
        (256, type_long, 1, CHART_WIDTH),  # ImageWidth
        (257, type_long, 1, CHART_HEIGHT),  # ImageLength
        (258, type_short, 3, bits_per_sample),  # BitsPerSample
        (259, type_short, 1, 1),  # Compression: none
        (262, type_short, 1, 2),  # PhotometricInterpretation: RGB
        (273, type_long, 1, 0),  # StripOffsets; filled after layout
        (274, type_short, 1, 1),  # Orientation: top-left
        (277, type_short, 1, 3),  # SamplesPerPixel
        (278, type_long, 1, CHART_HEIGHT),  # RowsPerStrip
        (279, type_long, 1, len(pixel_bytes)),  # StripByteCounts
        (282, type_rational, 1, x_resolution),  # XResolution
        (283, type_rational, 1, y_resolution),  # YResolution
        (284, type_short, 1, 1),  # PlanarConfiguration: chunky
        (296, type_short, 1, 2),  # ResolutionUnit: inch
        (305, type_ascii, len(software), software),  # Software
        (339, type_short, 3, sample_format),  # SampleFormat: unsigned
        (34675, type_undefined, len(icc_profile), icc_profile),  # ICCProfile
    ]
    entries.sort(key=lambda item: item[0])

    ifd_offset = 8
    ifd_size = 2 + len(entries) * 12 + 4
    next_data_offset = _align(ifd_offset + ifd_size)
    external_data: List[Tuple[int, bytes]] = []
    value_fields: Dict[int, bytes] = {}

    for tag, field_type, count, value in entries:
        payload_size = type_sizes[field_type] * count
        if isinstance(value, bytes):
            if len(value) != payload_size:
                raise AssertionError(
                    f"TIFF tag {tag} payload mismatch: "
                    f"{len(value)} != {payload_size}"
                )
            if payload_size <= 4:
                value_fields[tag] = value.ljust(4, b"\x00")
            else:
                offset = next_data_offset
                value_fields[tag] = struct.pack("<I", offset)
                external_data.append((offset, value))
                next_data_offset = _align(offset + len(value))
        else:
            value_fields[tag] = struct.pack("<I", int(value))

    pixel_offset = _align(next_data_offset)
    value_fields[273] = struct.pack("<I", pixel_offset)
    result = bytearray(pixel_offset + len(pixel_bytes))

    struct.pack_into("<2sHI", result, 0, b"II", 42, ifd_offset)
    struct.pack_into("<H", result, ifd_offset, len(entries))
    entry_offset = ifd_offset + 2
    for tag, field_type, count, _ in entries:
        struct.pack_into(
            "<HHI4s",
            result,
            entry_offset,
            tag,
            field_type,
            count,
            value_fields[tag],
        )
        entry_offset += 12
    struct.pack_into("<I", result, entry_offset, 0)

    for offset, payload in external_data:
        result[offset : offset + len(payload)] = payload
    result[pixel_offset : pixel_offset + len(pixel_bytes)] = pixel_bytes
    return bytes(result)


def _atomic_write_bytes(destination: Path, contents: bytes) -> None:
    """Atomically replace ``destination`` with ``contents``."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as file:
            temporary_path = Path(file.name)
            file.write(contents)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _atomic_copy(source: Path, destination: Path) -> None:
    """Atomically copy ``source`` to ``destination``."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as output:
            temporary_path = Path(output.name)
            with source.open("rb") as input_file:
                shutil.copyfileobj(input_file, output, 1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def generate_source_tiff(
    destination: Path,
    icc_profile_path: Path,
    overwrite: bool,
) -> Tuple[FileDigest, FileDigest]:
    """Generate the deterministic Rec.709/full-range RGB16 source TIFF."""

    if destination.exists() and not overwrite:
        raise ReferenceGenerationError(
            f"Source already exists: {destination}\n"
            "Pass --overwrite to regenerate it intentionally."
        )
    if not icc_profile_path.is_file():
        raise ReferenceGenerationError(
            f"Rec.709 ICC profile is missing: {icc_profile_path}"
        )

    icc_profile = icc_profile_path.read_bytes()
    tiff = _make_rec709_tiff(icc_profile)
    _atomic_write_bytes(destination, tiff)
    verify_source_tiff(destination, icc_profile)
    return _sha256(destination), _sha256(icc_profile_path)


def _read_tiff_values(
    data: bytes,
    byte_order: str,
    field_type: int,
    count: int,
    value_field: bytes,
) -> bytes:
    """Resolve an inline or out-of-line TIFF IFD value to its raw bytes."""

    type_sizes = {
        1: 1,  # BYTE
        2: 1,  # ASCII
        3: 2,  # SHORT
        4: 4,  # LONG
        5: 8,  # RATIONAL
        7: 1,  # UNDEFINED
    }
    if field_type not in type_sizes:
        raise ReferenceGenerationError(
            f"Source TIFF uses unsupported field type {field_type}."
        )
    byte_count = type_sizes[field_type] * count
    if byte_count <= 4:
        return value_field[:byte_count]
    offset = struct.unpack(f"{byte_order}I", value_field)[0]
    end = offset + byte_count
    if offset < 0 or end > len(data):
        raise ReferenceGenerationError(
            "Source TIFF contains an out-of-bounds IFD value."
        )
    return data[offset:end]


def _decode_tiff_unsigned_values(
    payload: bytes,
    byte_order: str,
    field_type: int,
    count: int,
) -> Tuple[int, ...]:
    """Decode TIFF SHORT or LONG values used by the source contract."""

    if field_type == 3:
        format_character = "H"
    elif field_type == 4:
        format_character = "I"
    else:
        raise ReferenceGenerationError(
            f"Expected TIFF SHORT or LONG, got field type {field_type}."
        )
    return struct.unpack(
        f"{byte_order}{count}{format_character}",
        payload,
    )


def verify_source_tiff(
    source: Path,
    expected_icc_profile: bytes,
) -> None:
    """Verify dimensions, encoding, profile, and all 729 chart patch values."""

    data = source.read_bytes()
    if len(data) < 8:
        raise ReferenceGenerationError("Source TIFF is truncated.")
    if data[:2] == b"II":
        byte_order = "<"
    elif data[:2] == b"MM":
        byte_order = ">"
    else:
        raise ReferenceGenerationError("Source TIFF has invalid byte order.")
    magic, ifd_offset = struct.unpack_from(f"{byte_order}HI", data, 2)
    if magic != 42:
        raise ReferenceGenerationError("Source is not a classic TIFF.")
    if ifd_offset + 2 > len(data):
        raise ReferenceGenerationError("Source TIFF IFD is out of bounds.")

    entry_count = struct.unpack_from(f"{byte_order}H", data, ifd_offset)[0]
    entries: Dict[int, Tuple[int, int, bytes]] = {}
    cursor = ifd_offset + 2
    for _ in range(entry_count):
        if cursor + 12 > len(data):
            raise ReferenceGenerationError("Source TIFF IFD is truncated.")
        tag, field_type, count = struct.unpack_from(
            f"{byte_order}HHI",
            data,
            cursor,
        )
        if tag in entries:
            raise ReferenceGenerationError(
                f"Source TIFF contains duplicate tag {tag}."
            )
        value_field = data[cursor + 8 : cursor + 12]
        entries[tag] = (
            field_type,
            count,
            _read_tiff_values(
                data,
                byte_order,
                field_type,
                count,
                value_field,
            ),
        )
        cursor += 12

    def unsigned_values(tag: int) -> Tuple[int, ...]:
        if tag not in entries:
            raise ReferenceGenerationError(
                f"Source TIFF is missing required tag {tag}."
            )
        field_type, count, payload = entries[tag]
        return _decode_tiff_unsigned_values(
            payload,
            byte_order,
            field_type,
            count,
        )

    expected_tags = {
        256: (CHART_WIDTH,),
        257: (CHART_HEIGHT,),
        258: (16, 16, 16),
        259: (1,),
        262: (2,),
        274: (1,),
        277: (3,),
        278: (CHART_HEIGHT,),
        284: (1,),
        339: (1, 1, 1),
    }
    for tag, expected in expected_tags.items():
        actual = unsigned_values(tag)
        if actual != expected:
            raise ReferenceGenerationError(
                f"Source TIFF tag {tag} mismatch: "
                f"expected {expected}, got {actual}."
            )

    if 34675 not in entries:
        raise ReferenceGenerationError(
            "Source TIFF does not contain an embedded ICC profile."
        )
    profile_type, profile_count, embedded_profile = entries[34675]
    if profile_type != 7 or profile_count != len(expected_icc_profile):
        raise ReferenceGenerationError(
            "Source TIFF ICC tag shape does not match ITU-709.icc."
        )
    if embedded_profile != expected_icc_profile:
        raise ReferenceGenerationError(
            "Source TIFF embeds a different ICC profile."
        )

    strip_offsets = unsigned_values(273)
    strip_byte_counts = unsigned_values(279)
    if len(strip_offsets) != 1 or len(strip_byte_counts) != 1:
        raise ReferenceGenerationError(
            "Source TIFF must contain one uncompressed strip."
        )
    pixel_offset = strip_offsets[0]
    pixel_byte_count = strip_byte_counts[0]
    expected_pixel_byte_count = CHART_WIDTH * CHART_HEIGHT * 3 * 2
    if pixel_byte_count != expected_pixel_byte_count:
        raise ReferenceGenerationError(
            "Source TIFF pixel byte count does not match the chart contract."
        )
    if pixel_offset + pixel_byte_count > len(data):
        raise ReferenceGenerationError("Source TIFF pixel strip is truncated.")

    for blue_index in range(LEVEL_COUNT):
        panel_x = blue_index % BLUE_PANEL_COUNT_PER_AXIS
        panel_y = blue_index // BLUE_PANEL_COUNT_PER_AXIS
        for green_index in range(LEVEL_COUNT):
            patch_y = panel_y * BLUE_PANEL_SIZE + green_index
            y = patch_y * PATCH_SIZE + PATCH_SIZE // 2
            for red_index in range(LEVEL_COUNT):
                patch_x = panel_x * BLUE_PANEL_SIZE + red_index
                x = patch_x * PATCH_SIZE + PATCH_SIZE // 2
                sample_offset = (
                    pixel_offset + (y * CHART_WIDTH + x) * 3 * 2
                )
                actual = struct.unpack_from(
                    f"{byte_order}HHH",
                    data,
                    sample_offset,
                )
                expected = (
                    _uint16_level(red_index),
                    _uint16_level(green_index),
                    _uint16_level(blue_index),
                )
                if actual != expected:
                    raise ReferenceGenerationError(
                        "Source chart patch mismatch at "
                        f"R={red_index}, G={green_index}, B={blue_index}: "
                        f"expected {expected}, got {actual}."
                    )


def _resolve_is_running() -> bool:
    """Return whether a process with Resolve's executable name is running."""

    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", "Resolve"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def _load_resolve_script_module() -> Any:
    """Import Blackmagic Design's installed DaVinciResolveScript module."""

    if not DEFAULT_RESOLVE_MODULES.is_dir():
        raise ReferenceGenerationError(
            f"Resolve scripting modules are missing: {DEFAULT_RESOLVE_MODULES}"
        )
    if not DEFAULT_RESOLVE_SCRIPT_LIBRARY.is_file():
        raise ReferenceGenerationError(
            "Resolve scripting library is missing: "
            f"{DEFAULT_RESOLVE_SCRIPT_LIBRARY}"
        )

    os.environ.setdefault(
        "RESOLVE_SCRIPT_API",
        str(DEFAULT_RESOLVE_MODULES.parent),
    )
    os.environ.setdefault(
        "RESOLVE_SCRIPT_LIB",
        str(DEFAULT_RESOLVE_SCRIPT_LIBRARY),
    )
    module_path = str(DEFAULT_RESOLVE_MODULES)
    if module_path not in sys.path:
        sys.path.insert(0, module_path)
    try:
        return importlib.import_module("DaVinciResolveScript")
    except ImportError as error:
        raise ReferenceGenerationError(
            "Unable to import DaVinciResolveScript. Use Apple's "
            "/usr/bin/python3 or another supported 64-bit Python."
        ) from error


def _wait_for_resolve_connection(
    script_module: Any,
    timeout_seconds: float,
    process: Optional[subprocess.Popen],
) -> Any:
    """Wait until the Resolve scripting bridge accepts a local connection."""

    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise ReferenceGenerationError(
                f"Headless Resolve exited with status {process.returncode}."
            )
        resolve = script_module.scriptapp("Resolve")
        if resolve is not None:
            return resolve
        time.sleep(0.25)
    raise ReferenceGenerationError(
        f"Resolve did not expose its scripting API within {timeout_seconds:g}s."
    )


def connect_to_resolve(
    launch_headless: bool,
    resolve_binary: Path,
    timeout_seconds: float,
) -> ResolveConnection:
    """Connect to Resolve, optionally launching a closed app in headless mode."""

    script_module = _load_resolve_script_module()
    is_running = _resolve_is_running()
    launched_process: Optional[subprocess.Popen] = None

    if is_running:
        resolve = _wait_for_resolve_connection(
            script_module,
            min(timeout_seconds, 10.0),
            None,
        )
        return ResolveConnection(resolve, None, False)

    if not launch_headless:
        raise ReferenceGenerationError(
            "DaVinci Resolve is not running. Start it with no project open, "
            "or pass --launch-headless while Resolve is fully closed."
        )
    if not resolve_binary.is_file():
        raise ReferenceGenerationError(
            f"Resolve executable is missing: {resolve_binary}"
        )

    launched_process = subprocess.Popen(
        [str(resolve_binary), "-nogui"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        resolve = _wait_for_resolve_connection(
            script_module,
            timeout_seconds,
            launched_process,
        )
    except BaseException:
        if launched_process.poll() is None:
            launched_process.terminate()
            try:
                launched_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                launched_process.kill()
                launched_process.wait(timeout=10)
        raise
    return ResolveConnection(resolve, launched_process, True)


def stop_owned_resolve(connection: ResolveConnection) -> None:
    """Quit only the headless Resolve process started by this tool."""

    if not connection.launched_by_tool or connection.has_been_stopped:
        return
    connection.resolve.Quit()
    process = connection.launched_process
    if process is not None:
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired as error:
            raise ReferenceGenerationError(
                "Headless Resolve did not quit within 30 seconds."
            ) from error
    connection.has_been_stopped = True


def assert_no_current_project(project_manager: Any) -> None:
    """Abort before any generation mutation when Resolve has a project open."""

    if project_manager is None:
        raise ResolveSafetyAbort(
            "Resolve did not expose a Project Manager, so the tool could not "
            "verify that no user project is open."
        )
    try:
        current_project = project_manager.GetCurrentProject()
    except Exception as error:
        raise ResolveSafetyAbort(
            "Resolve did not report whether a project is open. No LUT, "
            "project, or golden artifact was changed."
        ) from error
    if current_project is not None:
        try:
            name = current_project.GetName()
        except Exception:
            name = "<unknown>"
        raise ResolveSafetyAbort(
            "Resolve currently has a project open "
            f"({name!r}). No LUT, project, or golden artifact was changed. "
            "Close the project and leave Resolve at Project Manager, then retry."
        )


def _setting_values_match(expected: Any, actual: Any) -> bool:
    """Compare Resolve's textual setting representations semantically."""

    expected_text = str(expected).strip()
    actual_text = str(actual).strip()
    boolean_values = {
        "0": False,
        "false": False,
        "no": False,
        "off": False,
        "1": True,
        "true": True,
        "yes": True,
        "on": True,
    }
    expected_boolean = boolean_values.get(expected_text.lower())
    actual_boolean = boolean_values.get(actual_text.lower())
    if expected_boolean is not None and actual_boolean is not None:
        return expected_boolean == actual_boolean
    return expected_text.casefold() == actual_text.casefold()


def _set_and_verify_project_settings(
    project: Any,
    width: int,
    height: int,
    frame_rate: str,
) -> Dict[str, Dict[str, str]]:
    """Apply and round-trip every setting that defines the Rec.709 reference."""

    settings: Sequence[Tuple[str, str]] = (
        ("colorScienceMode", "davinciYRGB"),
        ("isAutoColorManage", "0"),
        ("separateColorSpaceAndGamma", "1"),
        ("colorSpaceTimeline", "Rec.709"),
        ("colorSpaceTimelineGamma", "Gamma 2.4"),
        ("colorSpaceOutput", "Rec.709"),
        ("colorSpaceOutputGamma", "Gamma 2.4"),
        ("useColorSpaceAwareGradingTools", "0"),
        ("videoDataLevels", "Full"),
        ("timelineFrameRate", frame_rate),
        ("timelinePlaybackFrameRate", frame_rate),
        ("timelineResolutionWidth", str(width)),
        ("timelineResolutionHeight", str(height)),
        ("timelineOutputResMatchTimelineRes", "1"),
    )
    verified: Dict[str, Dict[str, str]] = {}
    for key, expected in settings:
        if not project.SetSetting(key, expected):
            raise ReferenceGenerationError(
                f"Resolve rejected project setting {key}={expected!r}."
            )
        actual = project.GetSetting(key)
        if not _setting_values_match(expected, actual):
            raise ReferenceGenerationError(
                f"Resolve did not round-trip {key}: "
                f"expected {expected!r}, got {actual!r}."
            )
        verified[key] = {
            "requested": expected,
            "actual": str(actual),
        }
    return verified


def _inspect_lut_interpolation(
    project: Any,
    declared_interpolation: str,
) -> Dict[str, Any]:
    """Record interpolation, verifying it if Resolve exposes a public key."""

    snapshot = project.GetSetting()
    if isinstance(snapshot, Mapping):
        for key in ("interpolation3DLut", "Interpolation3DLut"):
            if key not in snapshot:
                continue
            actual = str(snapshot[key])
            if declared_interpolation.casefold() not in actual.casefold():
                raise ReferenceGenerationError(
                    "Resolve's LUT interpolation does not match the explicit "
                    f"confirmation: expected {declared_interpolation!r}, "
                    f"got {actual!r} from {key}."
                )
            return {
                "declared": declared_interpolation,
                "apiVerified": True,
                "apiKey": key,
                "apiValue": actual,
            }
    return {
        "declared": declared_interpolation,
        "apiVerified": False,
        "apiKey": None,
        "apiValue": None,
        "note": (
            "Resolve 21 does not expose 3D LUT interpolation through its "
            "documented Project setting API. The caller explicitly confirmed "
            "the fresh-project default selected in Resolve."
        ),
    }


def _stage_lut(source_lut: Path, source_digest: FileDigest) -> StagedLUT:
    """Copy a LUT into Resolve's master LUT tree under a content-addressed name."""

    staging_directory = DEFAULT_RESOLVE_LUT_ROOT / STAGED_LUT_FOLDER_NAME
    directory_existed = staging_directory.exists()
    destination: Optional[Path] = None
    created_by_tool = False
    try:
        staging_directory.mkdir(parents=True, exist_ok=True)

        safe_stem = re.sub(
            r"[^A-Za-z0-9._-]+",
            "-",
            source_lut.stem,
        ).strip("-")
        filename = f"{source_digest.sha256[:16]}-{safe_stem}.cube"
        destination = staging_directory / filename

        if destination.exists():
            existing_digest = _sha256(destination)
            if existing_digest.sha256 != source_digest.sha256:
                raise ReferenceGenerationError(
                    f"Staged LUT path has unexpected content: {destination}"
                )
        else:
            _atomic_copy(source_lut, destination)
            created_by_tool = True
            copied_digest = _sha256(destination)
            if copied_digest.sha256 != source_digest.sha256:
                raise ReferenceGenerationError(
                    f"Staged LUT hash mismatch: {destination}"
                )

        return StagedLUT(
            absolute_path=destination,
            resolve_relative_path=f"{STAGED_LUT_FOLDER_NAME}/{filename}",
            created_by_tool=created_by_tool,
            directory_created_by_tool=not directory_existed,
            expected_sha256=source_digest.sha256,
        )
    except Exception:
        if created_by_tool and destination is not None:
            destination.unlink(missing_ok=True)
        if not directory_existed:
            try:
                staging_directory.rmdir()
            except OSError:
                # Preserve a directory if another process populated it.
                pass
        raise


def _cleanup_staged_lut(staged_lut: Optional[StagedLUT]) -> List[str]:
    """Remove only LUT filesystem objects created by this process."""

    if staged_lut is None:
        return []
    errors: List[str] = []
    if staged_lut.created_by_tool:
        try:
            current_digest = _sha256(staged_lut.absolute_path)
            if current_digest.sha256 != staged_lut.expected_sha256:
                errors.append(
                    "Refused to remove staged LUT because its content changed: "
                    f"{staged_lut.absolute_path}"
                )
            else:
                staged_lut.absolute_path.unlink()
        except Exception as error:
            errors.append(f"Unable to remove staged LUT: {error}")

    if staged_lut.directory_created_by_tool:
        try:
            staged_lut.absolute_path.parent.rmdir()
        except OSError:
            # A non-empty directory may contain content created by another
            # process. It is intentionally preserved.
            pass
    return errors


def _cleanup_temporary_project(
    project_manager: Any,
    project: Any,
    project_name: Optional[str],
) -> List[str]:
    """Close and delete only the exact UUID-named project created by this run."""

    if project is None or project_name is None:
        return []
    expected_pattern = re.compile(
        rf"^{re.escape(TEMP_PROJECT_PREFIX)}"
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
        r"[0-9a-f]{4}-[0-9a-f]{12}$"
    )
    if expected_pattern.fullmatch(project_name) is None:
        return [
            "Refused to clean a project whose name is outside the generated "
            f"namespace: {project_name!r}"
        ]

    errors: List[str] = []
    try:
        if not project_manager.CloseProject(project):
            errors.append(
                f"Resolve did not close temporary project {project_name!r}."
            )
    except Exception as error:
        errors.append(f"Unable to close temporary project: {error}")

    try:
        if not project_manager.DeleteProject(project_name):
            errors.append(
                f"Resolve did not delete temporary project {project_name!r}."
            )
    except Exception as error:
        errors.append(f"Unable to delete temporary project: {error}")
    return errors


def _ensure_publish_targets_available(
    paths: ArtifactPaths,
    overwrite: bool,
) -> None:
    """Refuse accidental replacement unless explicitly authorized."""

    existing = [
        path
        for path in (
            paths.output,
            paths.manifest,
            paths.manifest_checksum,
        )
        if path.exists()
    ]
    if existing and not overwrite:
        formatted = "\n".join(f"  - {path}" for path in existing)
        raise ReferenceGenerationError(
            "Reference artifacts already exist:\n"
            f"{formatted}\nPass --overwrite to replace them intentionally."
        )


def _build_manifest(
    paths: ArtifactPaths,
    source_digest: FileDigest,
    lut_digest: FileDigest,
    output_digest: FileDigest,
    icc_profile_path: Path,
    icc_profile_digest: FileDigest,
    resolve_product_name: str,
    resolve_version: Sequence[Any],
    resolve_version_string: str,
    project_settings: Mapping[str, Mapping[str, str]],
    source_data_level: str,
    interpolation: Mapping[str, Any],
    graph_lut_value: str,
) -> Dict[str, Any]:
    """Build the machine-readable provenance for one Resolve golden."""

    generator_digest = _sha256(SCRIPT_PATH)
    return {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "generatedAtUTC": dt.datetime.now(
            dt.timezone.utc
        ).isoformat(timespec="seconds"),
        "generator": {
            "path": _display_path(SCRIPT_PATH),
            "sha256": generator_digest.sha256,
        },
        "resolve": {
            "productName": resolve_product_name,
            "version": list(resolve_version),
            "versionString": resolve_version_string,
        },
        "colorReference": {
            "primaries": "ITU-R BT.709",
            "transferFunction": "Gamma 2.4",
            "dataLevel": "Full",
            "colorScience": "DaVinci YRGB",
            "automaticColorManagement": False,
            "colorSpaceAwareGradingTools": False,
            "lutAmount": 1.0,
            "lutInterpolation": dict(interpolation),
        },
        "chart": {
            "width": CHART_WIDTH,
            "height": CHART_HEIGHT,
            "patchSize": PATCH_SIZE,
            "patchesPerAxis": PATCHES_PER_AXIS,
            "levelNumerators": list(LEVEL_NUMERATORS),
            "levelDenominator": 64,
            "layout": {
                "panelX": "blueIndex % 3",
                "panelY": "blueIndex / 3",
                "xPatch": "panelX * 9 + redIndex",
                "yPatch": "panelY * 9 + greenIndex",
                "axisOrder": (
                    "R left-to-right, G top-to-bottom, "
                    "B across 3x3 panels row-major"
                ),
            },
            "tiff": {
                "bitsPerSample": 16,
                "samplesPerPixel": 3,
                "compression": "none",
                "planarConfiguration": "chunky",
                "orientation": "top-left",
                "iccProfile": {
                    "path": str(icc_profile_path),
                    "sha256": icc_profile_digest.sha256,
                    "byteCount": icc_profile_digest.byte_count,
                },
            },
        },
        "projectSettings": dict(project_settings),
        "sourceClip": {
            "dataLevel": source_data_level,
        },
        "colorNode": {
            "nodeIndex": 1,
            "resolvedLUT": graph_lut_value,
        },
        "files": {
            "source": {
                "path": _display_path(paths.source),
                "sha256": source_digest.sha256,
                "byteCount": source_digest.byte_count,
            },
            "lut": {
                "path": _display_path(paths.lut),
                "sha256": lut_digest.sha256,
                "byteCount": lut_digest.byte_count,
            },
            "output": {
                "path": _display_path(paths.output),
                "sha256": output_digest.sha256,
                "byteCount": output_digest.byte_count,
            },
        },
        "manifestIntegrity": {
            "algorithm": "sha256",
            "sidecarPath": _display_path(paths.manifest_checksum),
        },
    }


def _publish_artifacts(
    temporary_output: Path,
    paths: ArtifactPaths,
    manifest: Mapping[str, Any],
) -> str:
    """Publish output, manifest, and manifest checksum atomically per file."""

    manifest_bytes = (
        json.dumps(
            manifest,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    checksum_bytes = (
        f"{manifest_hash}  {paths.manifest.name}\n"
    ).encode("utf-8")

    _atomic_copy(temporary_output, paths.output)
    _atomic_write_bytes(paths.manifest, manifest_bytes)
    _atomic_write_bytes(paths.manifest_checksum, checksum_bytes)
    return manifest_hash


def generate_resolve_reference(
    paths: ArtifactPaths,
    icc_profile_path: Path,
    launch_headless: bool,
    resolve_binary: Path,
    connection_timeout: float,
    overwrite: bool,
    frame_rate: str,
    confirmed_interpolation: str,
) -> Tuple[FileDigest, str]:
    """Generate and publish one Resolve LUT reference."""

    if not paths.lut.is_file():
        raise ReferenceGenerationError(
            f"Production LUT is missing: {paths.lut}"
        )

    connection = connect_to_resolve(
        launch_headless=launch_headless,
        resolve_binary=resolve_binary,
        timeout_seconds=connection_timeout,
    )
    project_manager = None
    project = None
    project_name: Optional[str] = None
    staged_lut: Optional[StagedLUT] = None

    try:
        # This is the only allowed check before any Resolve or output mutation.
        project_manager = connection.resolve.GetProjectManager()
        assert_no_current_project(project_manager)
        _ensure_publish_targets_available(paths, overwrite)

        if not icc_profile_path.is_file():
            raise ReferenceGenerationError(
                f"Rec.709 ICC profile is missing: {icc_profile_path}"
            )
        icc_profile = icc_profile_path.read_bytes()
        icc_profile_digest = _sha256(icc_profile_path)

        if not paths.source.exists():
            source_digest, generated_profile_digest = generate_source_tiff(
                paths.source,
                icc_profile_path,
                overwrite=False,
            )
            if generated_profile_digest != icc_profile_digest:
                raise ReferenceGenerationError(
                    "The Rec.709 ICC profile changed while generating the "
                    "source TIFF."
                )
        else:
            if not paths.source.is_file():
                raise ReferenceGenerationError(
                    f"Source TIFF is not a regular file: {paths.source}"
                )
            verify_source_tiff(paths.source, icc_profile)
            source_digest = _sha256(paths.source)
        lut_digest = _sha256(paths.lut)

        paths.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".resolve-lut-reference-",
            dir=paths.output.parent,
        ) as temporary_directory_string:
            temporary_directory = Path(temporary_directory_string)
            temporary_output = temporary_directory / "resolve-output.tiff"

            project_name = f"{TEMP_PROJECT_PREFIX}{uuid.uuid4()}"
            project = project_manager.CreateProject(
                project_name,
                str(temporary_directory),
            )
            if project is None:
                raise ReferenceGenerationError(
                    f"Resolve could not create temporary project {project_name!r}."
                )

            project_settings = _set_and_verify_project_settings(
                project,
                CHART_WIDTH,
                CHART_HEIGHT,
                frame_rate,
            )
            interpolation = _inspect_lut_interpolation(
                project,
                confirmed_interpolation,
            )

            staged_lut = _stage_lut(paths.lut, lut_digest)
            if not project.RefreshLUTList():
                raise ReferenceGenerationError(
                    "Resolve failed to refresh its LUT list."
                )

            media_pool = project.GetMediaPool()
            clips = media_pool.ImportMedia([str(paths.source.resolve())])
            if not clips or len(clips) != 1:
                raise ReferenceGenerationError(
                    "Resolve did not import exactly one source TIFF."
                )
            media_pool_item = clips[0]
            if not media_pool_item.SetClipProperty("Data Level", "Full"):
                raise ReferenceGenerationError(
                    "Resolve rejected source Data Level = Full."
                )
            source_data_level = str(
                media_pool_item.GetClipProperty("Data Level")
            )
            if not _setting_values_match("Full", source_data_level):
                raise ReferenceGenerationError(
                    "Resolve did not round-trip source Data Level = Full: "
                    f"{source_data_level!r}"
                )

            timeline = media_pool.CreateTimelineFromClips(
                "Resolve LUT Golden",
                clips,
            )
            if timeline is None:
                raise ReferenceGenerationError(
                    "Resolve could not create the reference timeline."
                )
            if not project.SetCurrentTimeline(timeline):
                raise ReferenceGenerationError(
                    "Resolve could not select the reference timeline."
                )

            items = timeline.GetItemListInTrack("video", 1)
            if not items or len(items) != 1:
                raise ReferenceGenerationError(
                    "Resolve reference timeline does not contain one video item."
                )
            graph = items[0].GetNodeGraph()
            if graph is None or graph.GetNumNodes() < 1:
                raise ReferenceGenerationError(
                    "Resolve did not expose the first Color node."
                )
            if not graph.SetLUT(1, staged_lut.resolve_relative_path):
                raise ReferenceGenerationError(
                    "Resolve failed to assign the production LUT to Color node 1."
                )
            graph_lut_value = str(graph.GetLUT(1))
            if staged_lut.absolute_path.stem not in graph_lut_value:
                raise ReferenceGenerationError(
                    "Resolve reported an unexpected LUT after assignment: "
                    f"{graph_lut_value!r}"
                )

            if not timeline.SetCurrentTimecode(timeline.GetStartTimecode()):
                raise ReferenceGenerationError(
                    "Resolve could not position the reference playhead."
                )
            if not project.ExportCurrentFrameAsStill(str(temporary_output)):
                raise ReferenceGenerationError(
                    "Resolve failed to export the current frame as TIFF."
                )
            if not temporary_output.is_file():
                raise ReferenceGenerationError(
                    "Resolve reported success but did not create the TIFF."
                )
            output_digest = _sha256(temporary_output)

            manifest = _build_manifest(
                paths=paths,
                source_digest=source_digest,
                lut_digest=lut_digest,
                output_digest=output_digest,
                icc_profile_path=icc_profile_path,
                icc_profile_digest=icc_profile_digest,
                resolve_product_name=str(connection.resolve.GetProductName()),
                resolve_version=connection.resolve.GetVersion(),
                resolve_version_string=str(
                    connection.resolve.GetVersionString()
                ),
                project_settings=project_settings,
                source_data_level=source_data_level,
                interpolation=interpolation,
                graph_lut_value=graph_lut_value,
            )

            project_cleanup_errors = _cleanup_temporary_project(
                project_manager,
                project,
                project_name,
            )
            if not project_cleanup_errors:
                project = None
                project_name = None

            staged_lut_cleanup_errors = _cleanup_staged_lut(staged_lut)
            if not staged_lut_cleanup_errors:
                staged_lut = None

            cleanup_errors = (
                project_cleanup_errors + staged_lut_cleanup_errors
            )
            if cleanup_errors:
                raise ReferenceGenerationError(
                    "Resolve generation succeeded, but cleanup was incomplete:\n"
                    + "\n".join(f"  - {error}" for error in cleanup_errors)
                )

            # Stop an owned headless process before publishing. A failed app
            # shutdown must not leave a new golden that appears fully complete.
            stop_owned_resolve(connection)
            manifest_hash = _publish_artifacts(
                temporary_output,
                paths,
                manifest,
            )
            return output_digest, manifest_hash
    finally:
        cleanup_errors: List[str] = []
        cleanup_errors.extend(
            _cleanup_temporary_project(
                project_manager,
                project,
                project_name,
            )
        )
        cleanup_errors.extend(_cleanup_staged_lut(staged_lut))
        try:
            stop_owned_resolve(connection)
        except Exception as error:
            cleanup_errors.append(str(error))
        if cleanup_errors:
            message = (
                "Cleanup failed:\n"
                + "\n".join(f"  - {error}" for error in cleanup_errors)
            )
            if sys.exc_info()[0] is None:
                raise ReferenceGenerationError(message)
            print(
                "Additional cleanup failure while preserving the original "
                f"error:\n{message}",
                file=sys.stderr,
            )


def _make_argument_parser() -> argparse.ArgumentParser:
    """Create the command-line contract for the generator."""

    parser = argparse.ArgumentParser(
        description=(
            "Generate a deterministic Rec.709/full-range LUT golden with "
            "DaVinci Resolve."
        )
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE_PATH,
        help=f"Source TIFF path (default: {DEFAULT_SOURCE_PATH})",
    )
    parser.add_argument(
        "--lut",
        type=Path,
        default=DEFAULT_LUT_PATH,
        help=f"Production .cube path (default: {DEFAULT_LUT_PATH})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PATH,
        help=f"Resolve golden TIFF path (default: {DEFAULT_OUTPUT_PATH})",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST_PATH,
        help=f"Provenance manifest path (default: {DEFAULT_MANIFEST_PATH})",
    )
    parser.add_argument(
        "--rec709-icc-profile",
        type=Path,
        default=DEFAULT_REC709_ICC_PROFILE,
        help=(
            "ICC profile embedded in the generated source "
            f"(default: {DEFAULT_REC709_ICC_PROFILE})"
        ),
    )
    parser.add_argument(
        "--generate-source-only",
        action="store_true",
        help=(
            "Generate the RGB16 TIFF without importing or launching Resolve."
        ),
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Intentionally replace existing generated artifacts.",
    )
    parser.add_argument(
        "--launch-headless",
        action="store_true",
        help=(
            "Launch Resolve with -nogui only when no Resolve process exists."
        ),
    )
    parser.add_argument(
        "--resolve-binary",
        type=Path,
        default=DEFAULT_RESOLVE_BINARY,
        help=f"Resolve executable path (default: {DEFAULT_RESOLVE_BINARY})",
    )
    parser.add_argument(
        "--connection-timeout",
        type=float,
        default=60.0,
        help="Seconds to wait for the Resolve scripting bridge (default: 60).",
    )
    parser.add_argument(
        "--frame-rate",
        default="30",
        help="Still timeline frame rate recorded in the project (default: 30).",
    )
    parser.add_argument(
        "--confirm-lut-interpolation",
        choices=("Trilinear", "Tetrahedral"),
        help=(
            "Required for Resolve generation. Explicitly confirms the 3D LUT "
            "interpolation selected by the fresh-project default."
        ),
    )
    return parser


def main(arguments: Optional[Sequence[str]] = None) -> int:
    """Run source generation or the full Resolve golden workflow."""

    parser = _make_argument_parser()
    options = parser.parse_args(arguments)
    paths = ArtifactPaths(
        source=options.source.resolve(),
        lut=options.lut.resolve(),
        output=options.output.resolve(),
        manifest=options.manifest.resolve(),
    )

    try:
        if options.generate_source_only:
            source_digest, profile_digest = generate_source_tiff(
                paths.source,
                options.rec709_icc_profile.resolve(),
                options.overwrite,
            )
            print(f"Generated source: {paths.source}")
            print(f"Source SHA-256: {source_digest.sha256}")
            print(f"Rec.709 ICC SHA-256: {profile_digest.sha256}")
            return 0

        if options.confirm_lut_interpolation is None:
            parser.error(
                "--confirm-lut-interpolation is required unless "
                "--generate-source-only is used."
            )
        if options.connection_timeout <= 0:
            parser.error("--connection-timeout must be greater than zero.")

        output_digest, manifest_hash = generate_resolve_reference(
            paths=paths,
            icc_profile_path=options.rec709_icc_profile.resolve(),
            launch_headless=options.launch_headless,
            resolve_binary=options.resolve_binary.resolve(),
            connection_timeout=options.connection_timeout,
            overwrite=options.overwrite,
            frame_rate=str(options.frame_rate),
            confirmed_interpolation=options.confirm_lut_interpolation,
        )
        print(f"Generated Resolve golden: {paths.output}")
        print(f"Output SHA-256: {output_digest.sha256}")
        print(f"Manifest: {paths.manifest}")
        print(f"Manifest SHA-256: {manifest_hash}")
        return 0
    except ResolveSafetyAbort as error:
        print(f"Safety abort: {error}", file=sys.stderr)
        return 2
    except ReferenceGenerationError as error:
        print(f"Reference generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
