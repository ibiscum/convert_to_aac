# convert_to_aac

Recursive audio processor for macOS that scans a source directory, converts .flac files to AAC (.m4a), and copies existing .aac/.m4a files while mirroring the original folder structure under a source-named folder inside the target directory.

## Features

- Recursively scans a source directory tree
- Converts .flac inputs to AAC in .m4a container
- Copies .aac and .m4a source files without re-encoding
- Mirrors relative paths and filenames under <target_dir>/<source_dir_name>
- Supports dry run mode to preview actions
- Supports debug mode for verbose logging
- Debug mode now includes FLAC/AAC `afinfo` excerpts and detailed CoreAudio/AVFoundation error diagnostics

## Requirements

- macOS (uses libFLAC + CoreAudio for encoding, AVFoundation for analysis/validation helpers)
- Swift 6.3+ toolchain (Swift Package Manager)
- libFLAC development library discoverable via `pkg-config` (e.g. Homebrew `flac`)

## Build

```bash
swift build
```

Build an optimized release binary:

```bash
swift build -c release
```

The resulting executable is:

- `.build/release/convert_to_aac`

> **Known warning (Command Line Tools-only setups):**
> On some recent macOS/Swift toolchain combinations, `swift build`/`swift test` may print linker warnings about missing paths under
> `/Library/Developer/CommandLineTools/Developer/...`.
> These warnings are typically benign when builds/tests otherwise succeed and can occur even with up-to-date Command Line Tools installed.

Install it system-wide (example: `/usr/local/bin`):

```bash
sudo install -m 0755 .build/release/convert_to_aac /usr/local/bin/convert_to_aac
```

## Tests

Run all tests:

```bash
swift test
```

The test suite includes:

- Unit tests for command-line parsing
- Unit tests for mirrored output path generation
- Unit tests for skip-existing-target logic and AAC metadata detection
- Regression tests for help and short usage output text
- Integration regression test for missing-argument stderr and exit code

## Usage

```bash
convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>
```

### Options

- -d: Enable debug output
- -n: Dry run (print operations without converting files)
- --explicit-lr: For multichannel FLAC, map only source channels 1/2 directly to output L/R
- -h, --help: Show help text

If called with invalid options or insufficient arguments, the program prints a short usage summary and suggests using -h.

## Behavior

- Input extensions matched case-insensitively: .flac, .aac, .m4a
- Converted output extension: .m4a
- Output codec settings: AAC-LC in .m4a with 256 kbps target bitrate (tries source sample rate first; falls back to 48 kHz, then 44.1 kHz if required by CoreAudio; channels capped to stereo)
- .aac and .m4a source files are copied to target path without conversion
- Metadata transfer runs only for converted .flac inputs (not for copied .aac/.m4a files)
- Metadata tags are read with ffprobe and written to the output .m4a with AtomicParsley
- Embedded cover art is extracted with ffmpeg and then injected into the output with AtomicParsley
- If ffprobe or AtomicParsley is missing, conversion still succeeds but metadata/artwork injection is skipped
- If ffmpeg is missing, conversion and metadata tag transfer still succeed, but cover art transfer is skipped
- If the expected target file already exists in the target folder and is a valid AAC file, processing is skipped
- Before converting a `.flac` source file, it is validated with `afinfo` to confirm FLAC format and non-empty audio data; invalid FLAC input causes immediate program exit with error
- `.flac` decoding uses `libFLAC` stream info (`sample_rate`, `bits_per_sample`) before audio frame conversion; decoded samples are scaled to full-range 32-bit signed PCM for CoreAudio input and then encoded to AAC `.m4a`
- CoreAudio AAC encoding first requests 32-bit integer PCM client input; if unsupported for a source/format combination, it automatically falls back to 32-bit float PCM client input
- FLAC decode/encode is streamed in blocks from `libFLAC` into CoreAudio (no full-track PCM buffer in memory)
- For FLAC sources, the output AAC encode target tries the source sample rate first (for example, 96 kHz), then automatically falls back to 48 kHz and 44.1 kHz if the source rate is rejected by CoreAudio
- For multichannel FLAC, default behavior downmixes to stereo; with `--explicit-lr`, output uses only source channels 1/2 as direct L/R mapping
- Multichannel stereo downmix applies fixed headroom and linear peak scaling (no compressor) before PCM32 conversion to avoid hard-clipping while preserving program dynamics
- AAC in `.m4a` does not preserve a fixed PCM bit depth value such as 24-bit; source bit depth is used during decode/input precision, while output is AAC-LC at the configured bitrate
- After each FLAC conversion, the generated `.m4a` is validated with `afinfo` to confirm AAC format and non-empty audio data; failed validation causes immediate program exit with error
- After each FLAC conversion, a quick post-conversion loudness sanity check runs on the generated AAC and logs peak/RMS levels in debug mode; suspiciously quiet outputs are flagged with a warning
- Hidden files and directories are skipped during traversal
- Source and target directories must be different and must not contain each other

## Metadata And Cover Art Processing

For each converted .flac file, processing happens in this order:

1. libFLAC decodes source audio and CoreAudio encodes AAC `.m4a`.
2. ffprobe reads source tags (JSON output).
3. AtomicParsley writes supported tags into a temporary .m4a output file.
4. ffmpeg attempts to extract the first embedded image stream as a temporary JPEG.
5. AtomicParsley injects that image as artwork into the same temporary .m4a output, and the temporary tagged file atomically replaces the target .m4a.

Supported tag mapping includes:

- title -> --title
- artist -> --artist
- album -> --album
- album_artist/albumartist -> --albumArtist
- composer -> --composer
- genre -> --genre
- comment/description -> --comment
- lyrics/unsyncedlyrics -> --lyrics
- track/tracknumber -> --tracknum
- disc/discnumber -> --disk
- date/year -> --year (first 4 digits)
- compilation -> --compilation (normalized to true/false)

Notes:

- Artwork transfer is best-effort. If no embedded image exists or extraction fails, conversion continues.
- Metadata processing is currently limited to converted .flac sources.
- Existing .aac/.m4a files are copied as-is, including whatever metadata they already contain.

## Conversion Quality

The converter uses libFLAC + CoreAudio with these audio settings for `.flac` inputs:

- Codec and container: AAC-LC in `.m4a`
- Target bitrate: `256 kbps`
- Sample rate: source rate preferred; automatic fallback to 48 kHz or 44.1 kHz when required by CoreAudio
- Channels: source channel count, capped to stereo (1-2 channels)

Why these settings were chosen:

- Good quality-to-size balance: AAC-LC at 256 kbps is typically transparent for most music libraries while staying smaller than lossless sources.
- Broad compatibility: AAC-LC in M4A is widely supported across Apple devices, players, and media servers.
- Stable batch behavior: fixed high-bitrate AAC settings reduce surprises across mixed source material during large recursive conversions.

Important quality notes:

- FLAC to AAC is lossy encoding from a lossless source; quality is high, but not lossless.
- FLAC source resolution (for example 24-bit/96 kHz) is handled correctly for AAC conversion: source precision is used during decode before AAC compression, and sample rate is preserved when supported by CoreAudio (with automatic fallback otherwise).
- Existing `.aac` and `.m4a` files are copied without re-encoding to avoid generation loss.

## Examples

Dry run to preview what would be converted:

```bash
convert_to_aac -n /Volumes/MusicLibrary /Volumes/AACLibrary
```

Convert with debug logs:

```bash
convert_to_aac -d /Volumes/MusicLibrary /Volumes/AACLibrary
```

Show help:

```bash
convert_to_aac -h
```

## Path Mirroring Example

Given:

- source_dir: /music/src
- target_dir: /music/aac
- found file: /music/src/artist/album/track01.flac

The output file will be:

- /music/aac/src/artist/album/track01.m4a
