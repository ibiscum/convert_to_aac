# convert_to_aac

Recursive audio processor for macOS that scans a source directory, converts .mp3/.flac files to AAC (.m4a), and copies existing .aac/.m4a files while mirroring the original folder structure in a target directory.

## Features

- Recursively scans a source directory tree
- Converts .mp3 and .flac inputs to AAC in .m4a container
- Copies .aac and .m4a source files without re-encoding
- Mirrors relative paths and filenames under the target directory
- Supports dry run mode to preview actions
- Supports debug mode for verbose logging

## Requirements

- macOS (uses /usr/bin/afconvert)
- Swift toolchain (Swift Package Manager)

## Build

```bash
swift build
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
swift run convert_to_aac [-d] [-n] <source_dir> <target_dir>
```

### Options

- -d: Enable debug output
- -n: Dry run (print operations without converting files)
- -h, --help: Show help text

If called with invalid options or insufficient arguments, the program prints a short usage summary and suggests using -h.

## Behavior

- Input extensions matched case-insensitively: .mp3, .flac, .aac, .m4a
- Converted output extension: .m4a
- Output codec settings: AAC-LC VBR highest quality (afconvert -u vbrq 127)
- .aac and .m4a source files are copied to target path without conversion
- After afconvert, metadata and embedded cover art are transferred from the source file using ffmpeg (audio is copied, not re-encoded)
- If ffmpeg is not installed, conversion still proceeds but metadata/artwork will not be preserved
- If target file already exists and validates as AAC, processing is skipped
- Hidden files and directories are skipped during traversal
- Source and target directory must be different

## Examples

Dry run to preview what would be converted:

```bash
swift run convert_to_aac -n /Volumes/MusicLibrary /Volumes/AACLibrary
```

Convert with debug logs:

```bash
swift run convert_to_aac -d /Volumes/MusicLibrary /Volumes/AACLibrary
```

Show help:

```bash
swift run convert_to_aac -h
```

## Path Mirroring Example

Given:

- source_dir: /music/src
- target_dir: /music/aac
- found file: /music/src/artist/album/track01.flac

The output file will be:

- /music/aac/artist/album/track01.m4a