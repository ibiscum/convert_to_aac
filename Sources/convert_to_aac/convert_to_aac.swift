import Foundation

@main
struct ConvertToAAC {
    private static let convertibleExtensions: Set<String> = ["mp3", "flac"]
    private static let copyOnlyExtensions: Set<String> = ["aac", "m4a"]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let logger = Logger(level: args.contains("-d") ? .debug : .info)

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
        let ffprobeURL = findExecutable(named: "ffprobe")
        let atomicParsleyURL = findExecutable(named: "AtomicParsley")

        if ffprobeURL == nil {
            logger.warning("ffprobe not found; metadata extraction will be skipped")
        }
        if atomicParsleyURL == nil {
            logger.warning("AtomicParsley not found; metadata injection will be skipped")
        }
        if ffmpegURL == nil {
            logger.warning("ffmpeg not found; MP3/FLAC cover art transfer will be skipped")
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
                    try convertToAAC(
                        source: fileURL,
                        target: outputURL,
                        ffmpegURL: ffmpegURL,
                        ffprobeURL: ffprobeURL,
                        atomicParsleyURL: atomicParsleyURL,
                        logger: logger
                    )
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

    private static func convertToAAC(
        source: URL,
        target: URL,
        ffmpegURL: URL?,
        ffprobeURL: URL?,
        atomicParsleyURL: URL?,
        logger: Logger
    ) throws {
        // Use AAC-LC in an M4A container and VBR highest quality.
        let afconvertResult = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: [
            "-f", "m4af",
            "-d", "aac",
            "-l", "Stereo",
            "-l", "Stereo",
            "-ch", "2",
            "-b", "256000",
            "-s", "2",
            "-q", "127",
            source.path,
            target.path,
            ],
            captureOutput: false
        )

        let renderedArgs = [
            "-f", "m4af",
            "-d", "aac",
            "-l", "Stereo",
            "-l", "Stereo",
            "-ch", "2",
            "-b", "256000",
            "-s", "2",
            "-q", "127",
            source.path,
            target.path,
        ].joined(separator: " ")
        logger.debug("Running: /usr/bin/afconvert \(renderedArgs)")

        if afconvertResult.terminationStatus != 0 {
            throw CLIError(afconvertResult.output.isEmpty ? "afconvert failed with unknown error" : afconvertResult.output)
        }

        // Transfer metadata using AtomicParsley. For MP3/FLAC, try to extract and inject artwork too.
        if let ffprobeURL = ffprobeURL, let atomicParsleyURL = atomicParsleyURL {
            logger.debug("Audio conversion finished for \(source.path); starting metadata transfer")
            do {
                try transferMetadata(
                    source: source,
                    target: target,
                    ffmpegURL: ffmpegURL,
                    ffprobeURL: ffprobeURL,
                    atomicParsleyURL: atomicParsleyURL,
                    logger: logger
                )
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

    private static func transferMetadata(
        source: URL,
        target: URL,
        ffmpegURL: URL?,
        ffprobeURL: URL,
        atomicParsleyURL: URL,
        logger: Logger
    ) throws {
        let sourceExt = source.pathExtension.lowercased()
        guard sourceExt == "mp3" || sourceExt == "flac" else {
            return
        }

        logger.debug("Metadata step: extracting tags from \(source.path)")
        let tags = try extractStandardTags(from: source, ffprobeURL: ffprobeURL)
        var atomicParsleyArgs = [target.path]

        appendAtomicParsleyTagArguments(from: tags, into: &atomicParsleyArgs)

        var temporaryArtworkURL: URL?
        if (sourceExt == "mp3" || sourceExt == "flac"), let ffmpegURL = ffmpegURL {
            logger.debug("Metadata step: extracting artwork from \(source.path)")
            do {
                temporaryArtworkURL = try extractArtworkFromSource(source: source, ffmpegURL: ffmpegURL)
                if let artworkURL = temporaryArtworkURL {
                    atomicParsleyArgs.append(contentsOf: ["--artwork", artworkURL.path])
                } else {
                    logger.warning("No embedded cover art found in \(source.path); continuing with other metadata")
                }
            } catch {
                logger.warning("Artwork extraction failed; continuing without artwork: \(error.localizedDescription)")
            }
        }

        atomicParsleyArgs.append("--overWrite")

        defer {
            if let temporaryArtworkURL {
                try? FileManager.default.removeItem(at: temporaryArtworkURL)
            }
        }

        let artworkInjected = temporaryArtworkURL != nil
        logger.debug("Metadata step: artwork injection for \(target.path): \(artworkInjected ? "enabled" : "disabled")")

        logger.debug("Running metadata transfer with AtomicParsley: \(atomicParsleyURL.path) \(atomicParsleyArgs.joined(separator: " "))")

        let result = try runProcess(
            executableURL: atomicParsleyURL,
            arguments: atomicParsleyArgs,
            timeoutSeconds: 30
        )
        if result.terminationStatus != 0 {
            throw CLIError(result.output.isEmpty ? "AtomicParsley failed with unknown error" : result.output)
        }

        logger.debug("Metadata step: AtomicParsley finished for \(target.path)")
    }

    private static func extractStandardTags(from source: URL, ffprobeURL: URL) throws -> [String: String] {
        let result = try runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format_tags",
                "-of", "json",
                source.path,
            ],
            timeoutSeconds: 20
        )

        if result.terminationStatus != 0 {
            throw CLIError(result.output.isEmpty ? "ffprobe failed with unknown error" : result.output)
        }

        guard let data = result.output.data(using: .utf8) else {
            return [:]
        }

        let decoded = try JSONDecoder().decode(FFprobeMetadata.self, from: data)
        return decoded.format?.tags ?? [:]
    }

    private static func appendAtomicParsleyTagArguments(from rawTags: [String: String], into args: inout [String]) {
        let tags = Dictionary(uniqueKeysWithValues: rawTags.map { ($0.key.lowercased(), $0.value) })

        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let candidate = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
                    return candidate
                }
            }
            return nil
        }

        if let title = value(["title"]) {
            args.append(contentsOf: ["--title", title])
        }
        if let artist = value(["artist"]) {
            args.append(contentsOf: ["--artist", artist])
        }
        if let album = value(["album"]) {
            args.append(contentsOf: ["--album", album])
        }
        if let albumArtist = value(["album_artist", "albumartist"]) {
            args.append(contentsOf: ["--albumArtist", albumArtist])
        }
        if let composer = value(["composer"]) {
            args.append(contentsOf: ["--composer", composer])
        }
        if let genre = value(["genre"]) {
            args.append(contentsOf: ["--genre", genre])
        }
        if let comment = value(["comment", "description"]) {
            args.append(contentsOf: ["--comment", comment])
        }
        if let lyrics = value(["lyrics", "unsyncedlyrics"]) {
            args.append(contentsOf: ["--lyrics", lyrics])
        }
        if let track = value(["track", "tracknumber"]) {
            args.append(contentsOf: ["--tracknum", track])
        }
        if let disk = value(["disc", "discnumber"]) {
            args.append(contentsOf: ["--disk", disk])
        }

        if let yearOrDate = value(["date", "year"]) {
            let year = String(yearOrDate.prefix(4))
            if year.count == 4 {
                args.append(contentsOf: ["--year", year])
            }
        }

        if let compilationRaw = value(["compilation"]) {
            let normalized = compilationRaw.lowercased()
            let isCompilation = normalized == "1" || normalized == "true" || normalized == "yes"
            args.append(contentsOf: ["--compilation", isCompilation ? "true" : "false"])
        }
    }

    private static func extractArtworkFromSource(source: URL, ffmpegURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let artworkURL = fileManager.temporaryDirectory
            .appendingPathComponent("convert_to_aac_artwork_\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        let result = try runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-nostdin",
                "-hide_banner",
                "-v", "error",
                "-y",
                "-i", source.path,
                "-an",
                "-map", "0:v:0?",
                "-frames:v", "1",
                "-c:v", "mjpeg",
                artworkURL.path,
            ],
            timeoutSeconds: 120
        )

        if result.terminationStatus != 0 {
            try? fileManager.removeItem(at: artworkURL)
            return nil
        }

        guard fileManager.fileExists(atPath: artworkURL.path) else {
            return nil
        }

        let attributes = try? fileManager.attributesOfItem(atPath: artworkURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if fileSize == 0 {
            try? fileManager.removeItem(at: artworkURL)
            return nil
        }

        return artworkURL
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        captureOutput: Bool = true,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var stdoutURL: URL?
        var stderrURL: URL?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?

        if captureOutput {
            let tempDir = FileManager.default.temporaryDirectory
            stdoutURL = tempDir.appendingPathComponent("convert_to_aac_stdout_\(UUID().uuidString).log")
            stderrURL = tempDir.appendingPathComponent("convert_to_aac_stderr_\(UUID().uuidString).log")

            guard
                let stdoutURL,
                let stderrURL,
                FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            else {
                throw CLIError("Failed to create temporary files for process output capture")
            }

            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        defer {
            try? stdoutHandle?.close()
            try? stderrHandle?.close()
            if let stdoutURL {
                try? FileManager.default.removeItem(at: stdoutURL)
            }
            if let stderrURL {
                try? FileManager.default.removeItem(at: stderrURL)
            }
        }

        try process.run()

        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                throw CLIError("Timed out after \(Int(timeoutSeconds))s running \(executableURL.lastPathComponent)")
            }
        } else {
            process.waitUntilExit()
        }

        var outputData = Data()
        if captureOutput {
            if let stdoutURL, let stdoutChunk = try? Data(contentsOf: stdoutURL) {
                outputData.append(stdoutChunk)
            }
            if let stderrURL, let stderrChunk = try? Data(contentsOf: stderrURL) {
                outputData.append(stderrChunk)
            }
        }

        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProcessResult(terminationStatus: process.terminationStatus, output: output)
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
        Metadata tags are transferred via ffprobe + AtomicParsley; artwork extraction uses ffmpeg.
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

struct Logger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    var logLevel: Level

    init(level: Level) {
        self.logLevel = level
    }

    private func shouldLog(_ level: Level) -> Bool {
        let order: [Level] = [.debug, .info, .warning, .error]
        guard let currentIndex = order.firstIndex(of: logLevel),
              let messageIndex = order.firstIndex(of: level) else {
            return false
        }
        return messageIndex >= currentIndex
    }

    private func log(_ level: Level, _ message: String) {
        guard shouldLog(level) else { return }
        var parts: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parts.append(formatter.string(from: Date()))
        parts.append(level.rawValue)
        parts.append(message)
        FileHandle.standardError.write((parts.joined(separator: ": ") + "\n").data(using: .utf8)!)
    }

    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warning(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }
}

struct Config {
    let debug: Bool
    let dryRun: Bool
    let sourceDirectory: String
    let targetDirectory: String
}

struct CLIError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct ProcessResult {
    let terminationStatus: Int32
    let output: String
}

struct FFprobeMetadata: Decodable {
    let format: FFprobeFormat?
}

struct FFprobeFormat: Decodable {
    let tags: [String: String]?
}
