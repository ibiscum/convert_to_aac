import Foundation
import Logging

@main
struct ConvertToAAC {
    private static let convertibleExtensions: Set<String> = ["mp3", "flac"]
    private static let copyOnlyExtensions: Set<String> = ["aac", "m4a"]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let logLevel: Logger.Level = args.contains("-d") ? .debug : .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = logLevel
            return handler
        }

        var logger = Logger(label: "convert_to_aac")
        logger.logLevel = logLevel

        do {
            switch try parseCommand(args) {
            case .help:
                logger.info("\(usageText())")
                Foundation.exit(EXIT_SUCCESS)
            case .run(let config):
                try run(config: config, logger: logger)
            }
        } catch let cliError as CLIError {
            logger.error("Error: \(cliError.message)")
            logger.info("\(shortUsageText())")
            Foundation.exit(EXIT_FAILURE)
        } catch {
            logger.error("Unexpected error: \(error.localizedDescription)")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(config: Config, logger: Logger) throws {
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

        let ffmpegURL = findExecutable(named: "ffmpeg")
        if ffmpegURL == nil {
            logger.warning("ffmpeg not found; metadata and cover art will not be preserved")
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
                logger.warning("Failed to access \(url.path): \(error.localizedDescription)")
                return true
            }
        ) else {
            throw CLIError("Failed to enumerate source directory: \(sourceURL.path)")
        }

        var scannedFiles = 0
        var matchedFiles = 0
        var skippedFiles = 0
        var copiedFiles = 0
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
            guard let action = sourceAction(forExtension: ext) else {
                continue
            }

            matchedFiles += 1

            let outputURL = try outputURL(for: fileURL, sourceRoot: sourceURL, targetRoot: targetURL, action: action)

            logger.debug("Source: \(fileURL.path)")
            logger.debug("Target: \(outputURL.path)")

            if shouldSkipConversion(targetURL: outputURL, aacValidator: {
                isValidAACFile(at: $0, logger: logger)
            }) {
                skippedFiles += 1
                if config.dryRun {
                    logger.info("[dry-run] skip existing valid AAC '\(outputURL.path)'")
                } else {
                    logger.debug("Skipping existing valid AAC: \(outputURL.path)")
                }
                continue
            }

            if config.dryRun {
                switch action {
                case .convertToM4A:
                    logger.info("[dry-run] afconvert '\(fileURL.path)' -> '\(outputURL.path)'")
                case .copyAAC:
                    logger.info("[dry-run] copy '\(fileURL.path)' -> '\(outputURL.path)'")
                }
                continue
            }

            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            do {
                switch action {
                case .convertToM4A:
                    try convertToAAC(source: fileURL, target: outputURL, ffmpegURL: ffmpegURL, logger: logger)
                    convertedFiles += 1
                case .copyAAC:
                    if fileManager.fileExists(atPath: outputURL.path) {
                        try fileManager.removeItem(at: outputURL)
                    }
                    try fileManager.copyItem(at: fileURL, to: outputURL)
                    copiedFiles += 1
                    logger.debug("Copied AAC source without conversion: \(fileURL.path)")
                }
            } catch {
                failedFiles += 1
                logger.error("Failed processing \(fileURL.path): \(error.localizedDescription)")
            }
        }

        logger.info("Scanned files: \(scannedFiles)")
        logger.info("Matched files (.mp3/.flac/.aac/.m4a): \(matchedFiles)")
        logger.info("Skipped existing valid AAC files: \(skippedFiles)")
        if config.dryRun {
            logger.info("Dry run complete; no files converted")
        } else {
            logger.info("Copied AAC source files: \(copiedFiles)")
            logger.info("Converted files: \(convertedFiles)")
            logger.info("Failed conversions: \(failedFiles)")
        }
    }

    private static func convertToAAC(source: URL, target: URL, ffmpegURL: URL?, logger: Logger) throws {
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

        let renderedArgs = process.arguments?.joined(separator: " ") ?? ""
        logger.debug("Running: /usr/bin/afconvert \(renderedArgs)")

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "afconvert failed with unknown error"
            throw CLIError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Transfer metadata/artwork from the source file without re-encoding.
        if let ffmpegURL = ffmpegURL {
            do {
                try transferMetadata(source: source, target: target, ffmpegURL: ffmpegURL, logger: logger)
            } catch {
                logger.warning("Metadata transfer failed: \(error.localizedDescription)")
            }
        }
    }

    static func findExecutable(named name: String) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/local/bin",
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }

        return nil
    }

    private static func transferMetadata(source: URL, target: URL, ffmpegURL: URL, logger: Logger) throws {
        let fileManager = FileManager.default
        let tempURL = target.deletingPathExtension().appendingPathExtension("tmp.m4a")

        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-y",
            "-i", target.path,
            "-i", source.path,
            "-map", "0:a",
            "-map_metadata", "1",
            "-c:a", "copy",
            "-movflags", "+faststart",
            tempURL.path,
        ]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        let renderedArgs = process.arguments?.joined(separator: " ") ?? ""
        logger.debug("Running metadata transfer: \(ffmpegURL.path) \(renderedArgs)")

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "ffmpeg failed with unknown error"
            try? fileManager.removeItem(at: tempURL)
            throw CLIError(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: tempURL, to: target)
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

    static func usageText() -> String {
        """
        Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>

        Recursively scans <source_dir> for .mp3, .flac, .aac, and .m4a files.
        .mp3/.flac are converted to AAC (.m4a); .aac/.m4a are copied as-is.
        Metadata and embedded cover art are transferred using ffmpeg when available.
        The directory structure is mirrored under <target_dir>.

        Options:
          -d    Enable debug output
          -n    Dry run (show what would be converted)
          -h    Show help
        """
    }

    static func shortUsageText() -> String {
        "Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>\nTry 'convert_to_aac -h' for more information.\n"
    }

    static func sourceAction(forExtension ext: String) -> SourceAction? {
        let normalized = ext.lowercased()
        if convertibleExtensions.contains(normalized) {
            return .convertToM4A
        }
        if copyOnlyExtensions.contains(normalized) {
            return .copyAAC
        }
        return nil
    }

    static func outputURL(for sourceFile: URL, sourceRoot: URL, targetRoot: URL, action: SourceAction) throws -> URL {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let filePath = sourceFile.standardizedFileURL.path

        guard filePath.hasPrefix(sourcePath + "/") else {
            throw CLIError("Input file is not within source directory: \(filePath)")
        }

        let relativePath = String(filePath.dropFirst(sourcePath.count + 1))
        let outputRelative: String
        switch action {
        case .convertToM4A:
            let relativeWithoutExt = (relativePath as NSString).deletingPathExtension
            outputRelative = relativeWithoutExt + ".m4a"
        case .copyAAC:
            outputRelative = relativePath
        }
        return targetRoot.standardizedFileURL.appendingPathComponent(outputRelative)
    }

    static func shouldSkipConversion(
        targetURL: URL,
        fileManager: FileManager = .default,
        aacValidator: (URL) -> Bool
    ) -> Bool {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return false
        }
        return aacValidator(targetURL)
    }

    static func isAACMetadataOutput(_ output: String) -> Bool {
        let normalized = output.lowercased()
        guard normalized.contains("data format") else {
            return false
        }
        return normalized.contains("aac")
    }

    static func isValidAACFile(at fileURL: URL, logger: Logger) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        process.arguments = [fileURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                logger.debug("afinfo reported non-AAC or unreadable file: \(fileURL.path)")
                return false
            }

            return isAACMetadataOutput(output)
        } catch {
            logger.debug("Failed to run afinfo for \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }
}

enum ParsedCommand {
    case help
    case run(Config)
}

enum SourceAction {
    case convertToM4A
    case copyAAC
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
