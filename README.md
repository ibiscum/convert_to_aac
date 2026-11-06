# convert_to_aac

Recursive audio processor for macOS that scans a source directory, converts .mp3/.flac files to AAC (.m4a), and copies existing .aac/.m4a files while mirroring the original folder structure under a source-named folder inside the target directory.

## Features

- Recursively scans a source directory tree
- Converts .mp3 and .flac inputs to AAC in .m4a container
- Copies .aac and .m4a source files without re-encoding
- Mirrors relative paths and filenames under <target_dir>/<source_dir_name>
- Supports dry run mode to preview actions
- Supports debug mode for verbose logging
- Debug mode now includes FLAC/AAC `afinfo` excerpts and AVFoundation error domain/code details for failed conversions

## Requirements

- macOS (uses AVFoundation for AAC encoding)
- Swift toolchain (Swift Package Manager)
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
convert_to_aac [-d] [-n] <source_dir> <target_dir>
```

### Options

- -d: Enable debug output
- -n: Dry run (print operations without converting files)
- -h, --help: Show help text

If called with invalid options or insufficient arguments, the program prints a short usage summary and suggests using -h.

## Behavior

- Input extensions matched case-insensitively: .mp3, .flac, .aac, .m4a
- Converted output extension: .m4a
- Output codec settings: AAC-LC in .m4a with 256 kbps target bitrate (source sample rate preserved, channels capped to stereo)
- .aac and .m4a source files are copied to target path without conversion
- Metadata transfer runs only for converted .mp3 and .flac inputs (not for copied .aac/.m4a files)
- Metadata tags are read with ffprobe and written to the output .m4a with AtomicParsley
- Embedded cover art is extracted with ffmpeg and then injected into the output with AtomicParsley
- If ffprobe or AtomicParsley is missing, conversion still succeeds but metadata/artwork injection is skipped
- If ffmpeg is missing, conversion and metadata tag transfer still succeed, but cover art transfer is skipped
- If the expected target file already exists in the target folder and is a valid AAC file, processing is skipped
- Before converting a `.flac` source file, it is validated with `afinfo` to confirm FLAC format and non-empty audio data; invalid FLAC input causes immediate program exit with error
- `.flac` decoding uses `libFLAC` stream info (`sample_rate`, `bits_per_sample`) before audio frame conversion; decoded samples are scaled to full-range 32-bit signed PCM for CoreAudio input and then encoded to AAC `.m4a`
- For FLAC sources, the output AAC encode target uses the source sample rate (for example, 96 kHz FLAC is encoded as 96 kHz AAC when supported by CoreAudio)
- AAC in `.m4a` does not preserve a fixed PCM bit depth value such as 24-bit; source bit depth is used during decode/input precision, while output is AAC-LC at the configured bitrate
- After each MP3/FLAC conversion, the generated `.m4a` is validated with `afinfo` to confirm AAC format and non-empty audio data; failed validation causes immediate program exit with error
- After each FLAC conversion, a quick post-conversion loudness sanity check runs on the generated AAC and logs peak/RMS levels in debug mode; suspiciously quiet outputs are flagged with a warning
- Hidden files and directories are skipped during traversal
- Source and target directory must be different

## Metadata And Cover Art Processing

For each converted .mp3/.flac file, processing happens in this order:

1. AVFoundation transcodes source audio to AAC `.m4a`.
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
- Metadata processing is currently limited to converted .mp3 and .flac sources.
- Existing .aac/.m4a files are copied as-is, including whatever metadata they already contain.

## Conversion Quality

The converter uses AVFoundation (`AVAssetReader` + `AVAssetWriter`) with these audio settings for `.mp3` and `.flac` inputs:

- Codec and container: AAC-LC in `.m4a`
- Target bitrate: `256 kbps`
- Sample rate: preserved from source track/stream info when available (fallback `44.1 kHz` for AVFoundation path)
- Channels: source channel count, capped to stereo (1-2 channels)

Why these settings were chosen:

- Good quality-to-size balance: AAC-LC at 256 kbps is typically transparent for most music libraries while staying smaller than lossless sources.
- Broad compatibility: AAC-LC in M4A is widely supported across Apple devices, players, and media servers.
- Stable batch behavior: fixed high-bitrate AAC settings reduce surprises across mixed source material during large recursive conversions.

Important quality notes:

- MP3 to AAC is a lossy-to-lossy transcode. If your source MP3 was already low bitrate, quality cannot be improved by conversion.
- FLAC to AAC is lossy encoding from a lossless source; quality is high, but not lossless.
- FLAC source resolution (for example 24-bit/96 kHz) is handled correctly for AAC conversion: sample rate is retained, and source precision is used during decode before AAC compression.
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
