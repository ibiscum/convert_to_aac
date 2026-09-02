import Foundation

@main
struct ConvertToAAC {
    private static let supportedExtensions: Set<String> = ["mp3", "flac"]

    static func main() {
        do {
            switch try parseCommand(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                printUsage()
                Foundation.exit(EXIT_SUCCESS)
            case .run(let config):
                try run(config: config)
            }
        } catch let cliError as CLIError {
            fputs("Error: \(cliError.message)\n", stderr)
            printShortUsage()
            Foundation.exit(EXIT_FAILURE)
        } catch {
            fputs("Unexpected error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(config: Config) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: config.sourceDirectory).standardizedFileURL
        let targetURL = URL(fileURLWithPath: config.targetDirectory).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("Source directory does not exist or is not a directory: \(sourceURL.path)")
        }

        if sourceURL.path == targetURL.path {
            throw CLIError("Source and target directory must be different")
        }

        if !config.dryRun {
            try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                fputs("Warning: failed to access \(url.path): \(error.localizedDescription)\n", stderr)
                return true
            }
        ) else {
            throw CLIError("Failed to enumerate source directory: \(sourceURL.path)")
        }

        var scannedFiles = 0
        var matchedFiles = 0
        var convertedFiles = 0
        var failedFiles = 0

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            scannedFiles += 1
            let ext = fileURL.pathExtension.lowercased()
            if !supportedExtensions.contains(ext) {
                continue
            }

            matchedFiles += 1

            let outputURL = try outputURL(for: fileURL, sourceRoot: sourceURL, targetRoot: targetURL)

            if config.debug {
                print("[debug] source: \(fileURL.path)")
                print("[debug] target: \(outputURL.path)")
            }

            if config.dryRun {
                print("[dry-run] afconvert '\(fileURL.path)' -> '\(outputURL.path)'")
                continue
            }

            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            do {
                try convertToAAC(source: fileURL, target: outputURL, debug: config.debug)
                convertedFiles += 1
            } catch {
                failedFiles += 1
                fputs("Failed converting \(fileURL.path): \(error.localizedDescription)\n", stderr)
            }
        }

        print("Scanned files: \(scannedFiles)")
        print("Matched files (.mp3/.flac): \(matchedFiles)")
        if config.dryRun {
            print("Dry run complete; no files converted")
        } else {
            print("Converted files: \(convertedFiles)")
            print("Failed conversions: \(failedFiles)")
        }
    }

    private static func convertToAAC(source: URL, target: URL, debug: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")

        // Use AAC-LC in an M4A container and VBR highest quality.
        process.arguments = [
            "-f", "m4af",
            "-d", "aac",
            "-u", "vbrq", "127",
            source.path,
            target.path,
        ]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        if debug {
            let renderedArgs = process.arguments?.joined(separator: " ") ?? ""
            print("[debug] running: /usr/bin/afconvert \(renderedArgs)")
        }

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "afconvert failed with unknown error"
            throw CLIError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func parseCommand(_ args: [String]) throws -> ParsedCommand {
        var debug = false
        var dryRun = false
        var positional: [String] = []

        for arg in args {
            switch arg {
            case "-d":
                debug = true
            case "-n":
                dryRun = true
            case "-h", "--help":
                return .help
            default:
                if arg.hasPrefix("-") {
                    throw CLIError("Unknown option: \(arg)")
                }
                positional.append(arg)
            }
        }

        guard positional.count == 2 else {
            throw CLIError("Expected exactly 2 arguments: <source_dir> <target_dir>")
        }

        return .run(
            Config(
                debug: debug,
                dryRun: dryRun,
                sourceDirectory: positional[0],
                targetDirectory: positional[1]
            )
        )
    }

    private static func printUsage() {
        print(usageText())
    }

    private static func printShortUsage() {
        fputs(shortUsageText(), stderr)
    }

    static func usageText() -> String {
        """
        Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>

        Recursively scans <source_dir> for .mp3 and .flac files, then converts
        them to AAC (.m4a) and mirrors the directory structure under <target_dir>.

        Options:
          -d    Enable debug output
          -n    Dry run (show what would be converted)
          -h    Show help
        """
    }

    static func shortUsageText() -> String {
        "Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>\nTry 'convert_to_aac -h' for more information.\n"
    }

    static func outputURL(for sourceFile: URL, sourceRoot: URL, targetRoot: URL) throws -> URL {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let filePath = sourceFile.standardizedFileURL.path

        guard filePath.hasPrefix(sourcePath + "/") else {
            throw CLIError("Input file is not within source directory: \(filePath)")
        }

        let relativePath = String(filePath.dropFirst(sourcePath.count + 1))
        let relativeWithoutExt = (relativePath as NSString).deletingPathExtension
        let outputRelative = relativeWithoutExt + ".m4a"
        return targetRoot.standardizedFileURL.appendingPathComponent(outputRelative)
    }
}

enum ParsedCommand {
    case help
    case run(Config)
}

struct Config {
    let debug: Bool
    let dryRun: Bool
    let sourceDirectory: String
    let targetDirectory: String
}

struct CLIError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
