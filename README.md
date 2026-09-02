# convert_to_aac

Recursive audio converter for macOS that finds .mp3 and .flac files in a source directory and converts them to AAC (.m4a) while mirroring the original folder structure in a target directory.

## Features

- Recursively scans a source directory tree
- Converts .mp3 and .flac inputs to AAC in .m4a container
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
- Regression tests for help and short usage output text

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

- Input extensions matched case-insensitively: .mp3, .flac
- Output extension: .m4a
- Output codec settings: AAC-LC VBR highest quality (afconvert -u vbrq 127)
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