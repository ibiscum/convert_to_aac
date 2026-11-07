import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CFLAC

@main
struct ConvertToAAC {
    private static let convertibleExtensions: Set<String> = ["flac"]
    private static let copyOnlyExtensions: Set<String> = ["aac", "m4a"]

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        do {
            switch try parseCommand(args) {
            case .help:
                let logger = Logger(level: args.contains("-d") ? .debug : .info)
                logger.info("\(usageText())")
                Foundation.exit(EXIT_SUCCESS)
            case .run(let config):
                let logger = Logger(level: config.debug ? .debug : .info)
                try await run(config: config, logger: logger)
            }
        } catch let cliError as CLIError {
            let logger = Logger(level: args.contains("-d") ? .debug : .info)
            logger.error("Error: \(cliError.message)")
            logger.info("\(shortUsageText())")
            Foundation.exit(EXIT_FAILURE)
        } catch {
            let logger = Logger(level: args.contains("-d") ? .debug : .info)
            logger.error("Unexpected error: \(error.localizedDescription)")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(config: Config, logger: Logger) async throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: config.sourceDirectory).standardizedFileURL
        let targetURL = URL(fileURLWithPath: config.targetDirectory).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("Source directory does not exist or is not a directory: \(sourceURL.path)")
        }

        try validateSourceAndTargetDirectories(sourceURL: sourceURL, targetURL: targetURL)

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
            logger.warning("ffmpeg not found; FLAC cover art transfer will be skipped")
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

        while let fileURL = enumerator.nextObject() as? URL {
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
                isValidAACFileWithAudioData(at: $0, logger: logger)
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
                    logger.info("[dry-run] flac-coreaudio-encode '\(fileURL.path)' -> '\(outputURL.path)'")
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
                    try await convertToAAC(
                        source: fileURL,
                        target: outputURL,
                        explicitLRChannels: config.explicitLRChannels,
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
            } catch let validationError as AudioValidationError {
                throw CLIError(validationError.localizedDescription)
            } catch {
                failedFiles += 1
                logger.error("Failed processing \(fileURL.path): \(error.localizedDescription)")
            }
        }

        logger.info("Scanned files: \(scannedFiles)")
        logger.info("Matched files (.flac/.aac/.m4a): \(matchedFiles)")
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
        explicitLRChannels: Bool,
        ffmpegURL: URL?,
        ffprobeURL: URL?,
        atomicParsleyURL: URL?,
        logger: Logger
    ) async throws {
        logger.debug("Starting conversion: \(source.path) -> \(target.path)")

        let sourceExt = source.pathExtension.lowercased()
        guard sourceExt == "flac" else {
            throw CLIError("Unsupported convertible source extension: .\(sourceExt)")
        }
        guard isValidFLACFileWithAudioData(at: source, logger: logger) else {
            throw AudioValidationError.invalidSourceFLAC(path: source.path)
        }

        do {
            try convertFLACToAACUsingLibFLAC(
                source: source,
                target: target,
                explicitLRChannels: explicitLRChannels,
                logger: logger
            )
        } catch {
            logger.error("Audio conversion failed for \(source.path): \(error.localizedDescription)")
            throw error
        }

        // Transfer metadata using AtomicParsley. For FLAC, try to extract and inject artwork too.
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

        guard isValidAACFileWithAudioData(at: target, logger: logger) else {
            throw AudioValidationError.invalidConvertedM4A(path: target.path)
        }

        await logPostConversionLoudnessSanity(for: target, logger: logger)
    }

    private static func convertFLACToAACUsingLibFLAC(
        source: URL,
        target: URL,
        explicitLRChannels: Bool,
        logger: Logger
    ) throws {
        guard let decoder = FLAC__stream_decoder_new() else {
            throw CLIError("libFLAC failed to initialize decoder for \(source.path)")
        }
        defer {
            FLAC__stream_decoder_delete(decoder)
        }

        let state = FLACDecoderState(explicitLRChannels: explicitLRChannels)
        let initStatus = source.path.withCString { sourceCString in
            FLAC__stream_decoder_init_file(
                decoder,
                sourceCString,
                flacWriteCallback,
                flacMetadataCallback,
                flacErrorCallback,
                Unmanaged.passUnretained(state).toOpaque()
            )
        }
        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            throw CLIError("libFLAC failed to open \(source.path): init status \(initStatus.rawValue)")
        }

        guard FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0 else {
            throw CLIError("libFLAC failed while reading stream metadata for \(source.path)")
        }

        guard let sampleRate = state.sampleRate, sampleRate > 0 else {
            throw CLIError("libFLAC did not report sample rate for \(source.path)")
        }
        guard let bitsPerSample = state.bitsPerSample, bitsPerSample > 0 else {
            throw CLIError("libFLAC did not report bits per sample for \(source.path)")
        }
        guard bitsPerSample <= 32 else {
            throw CLIError("Unsupported FLAC bit depth \(bitsPerSample) for \(source.path)")
        }
        guard let sourceChannels = state.sourceChannels, sourceChannels > 0 else {
            throw CLIError("libFLAC did not report channel count for \(source.path)")
        }
        let outputChannels = normalizedFLACOutputChannels(
            sourceChannels: sourceChannels,
            explicitLRChannels: explicitLRChannels
        )
        state.outputChannels = outputChannels

        if explicitLRChannels, sourceChannels > 2 {
            logger.warning("Applying explicit LR channel mapping for \(source.path); channels 3+ will be ignored")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        state.encoder = try createCoreAudioAACEncoder(
            target: target,
            sampleRate: Double(sampleRate),
            channels: outputChannels,
            logger: logger
        )

        guard FLAC__stream_decoder_process_until_end_of_stream(decoder) != 0 else {
            if let writeFailure = state.writeFailure {
                throw CLIError(writeFailure)
            }
            throw CLIError("libFLAC failed while decoding \(source.path)")
        }

        if let writeFailure = state.writeFailure {
            throw CLIError(writeFailure)
        }

        if !state.decodeErrorMessages.isEmpty {
            logger.warning("libFLAC decode warnings for \(source.path): \(state.decodeErrorMessages.joined(separator: ", "))")
        }

        guard state.totalFrames > 0 else {
            throw CLIError("libFLAC produced no PCM frames for \(source.path)")
        }
        logger.debug(
            "Running libFLAC decode + CoreAudio AAC encode (\(source.path) -> \(target.path)); " +
            "sampleRate=\(sampleRate), sourceBitsPerSample=\(bitsPerSample), " +
            "sourceChannels=\(sourceChannels), outputChannels=\(outputChannels), frames=\(state.totalFrames), " +
            "explicitLR=\(explicitLRChannels)"
        )
    }

    private static func createCoreAudioAACEncoder(
        target: URL,
        sampleRate: Double,
        channels: UInt32,
        logger: Logger
    ) throws -> FLACEncoderSession {
        let outputSampleRateCandidates = aacEncodeSampleRateCandidates(sourceSampleRate: sampleRate)
        var attemptErrors: [String] = []

        for outputSampleRate in outputSampleRateCandidates {
            do {
                let session = try createCoreAudioAACEncoderSession(
                    target: target,
                    sourceSampleRate: sampleRate,
                    outputSampleRate: outputSampleRate,
                    channels: channels,
                    logger: logger
                )
                if outputSampleRate != sampleRate {
                    logger.warning(
                        "CoreAudio AAC output sample rate fallback for \(target.path): " +
                        "source \(Int(sampleRate)) Hz -> output \(Int(outputSampleRate)) Hz"
                    )
                }
                return session
            } catch let error as CLIError {
                attemptErrors.append("\(Int(outputSampleRate)) Hz: \(error.message)")
            } catch {
                attemptErrors.append("\(Int(outputSampleRate)) Hz: \(error.localizedDescription)")
            }
        }

        throw CLIError(
            "Failed to initialize CoreAudio AAC encoder for \(target.path). Attempts: " +
            attemptErrors.joined(separator: " | ")
        )
    }

    private static func createCoreAudioAACEncoderSession(
        target: URL,
        sourceSampleRate: Double,
        outputSampleRate: Double,
        channels: UInt32,
        logger: Logger
    ) throws -> FLACEncoderSession {
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(
            AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo,
                0,
                nil,
                &formatSize,
                &outputFormat
            ),
            context: "AudioFormatGetProperty(kAudioFormatProperty_FormatInfo)"
        )

        var outputFile: ExtAudioFileRef?
        try checkOSStatus(
            ExtAudioFileCreateWithURL(
                target as CFURL,
                kAudioFileM4AType,
                &outputFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &outputFile
            ),
            context: "ExtAudioFileCreateWithURL(\(target.path))"
        )
        guard let outputFile else {
            throw CLIError("CoreAudio failed to create output file for \(target.path)")
        }

        let clientSampleFormat: FLACEncoderClientSampleFormat
        do {
            clientSampleFormat = try setCoreAudioClientDataFormat(
                outputFile: outputFile,
                sourceSampleRate: sourceSampleRate,
                channels: channels,
                targetPath: target.path,
                logger: logger
            )
        } catch {
            ExtAudioFileDispose(outputFile)
            throw error
        }

        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try checkOSStatus(
            ExtAudioFileGetProperty(
                outputFile,
                kExtAudioFileProperty_AudioConverter,
                &converterSize,
                &converter
            ),
            context: "ExtAudioFileGetProperty(kExtAudioFileProperty_AudioConverter)"
        )
        guard let converter else {
            throw CLIError("CoreAudio did not provide an AudioConverter for \(target.path)")
        }

        var bitRateControlMode = UInt32(kAudioCodecBitRateControlMode_VariableConstrained)
        try checkOSStatus(
            AudioConverterSetProperty(
                converter,
                kAudioCodecPropertyBitRateControlMode,
                UInt32(MemoryLayout<UInt32>.size),
                &bitRateControlMode
            ),
            context: "AudioConverterSetProperty(kAudioCodecPropertyBitRateControlMode)"
        )

        var vbrQuality: UInt32 = 127
        try checkOSStatus(
            AudioConverterSetProperty(
                converter,
                kAudioCodecPropertySoundQualityForVBR,
                UInt32(MemoryLayout<UInt32>.size),
                &vbrQuality
            ),
            context: "AudioConverterSetProperty(kAudioCodecPropertySoundQualityForVBR)"
        )

        var codecQuality: UInt32 = 127
        try checkOSStatus(
            AudioConverterSetProperty(
                converter,
                kAudioConverterCodecQuality,
                UInt32(MemoryLayout<UInt32>.size),
                &codecQuality
            ),
            context: "AudioConverterSetProperty(kAudioConverterCodecQuality)"
        )

        var targetBitRate: UInt32 = 256_000
        try checkOSStatus(
            AudioConverterSetProperty(
                converter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &targetBitRate
            ),
            context: "AudioConverterSetProperty(kAudioConverterEncodeBitRate)"
        )

        return FLACEncoderSession(
            outputFile: outputFile,
            targetPath: target.path,
            channels: channels,
            clientSampleFormat: clientSampleFormat
        )
    }

    private static func setCoreAudioClientDataFormat(
        outputFile: ExtAudioFileRef,
        sourceSampleRate: Double,
        channels: UInt32,
        targetPath: String,
        logger: Logger
    ) throws -> FLACEncoderClientSampleFormat {
        var int32ClientFormat = pcmClientFormat(
            sampleRate: sourceSampleRate,
            channels: channels,
            sampleFormat: .int32
        )
        let int32ClientFormatStatus = ExtAudioFileSetProperty(
            outputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &int32ClientFormat
        )
        if int32ClientFormatStatus == noErr {
            return .int32
        }

        var float32ClientFormat = pcmClientFormat(
            sampleRate: sourceSampleRate,
            channels: channels,
            sampleFormat: .float32
        )
        let float32ClientFormatStatus = ExtAudioFileSetProperty(
            outputFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &float32ClientFormat
        )
        guard float32ClientFormatStatus == noErr else {
            throw CLIError(
                "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat) failed " +
                "for int32 status \(formatOSStatus(int32ClientFormatStatus)) and float32 status \(formatOSStatus(float32ClientFormatStatus))"
            )
        }

        logger.warning(
            "CoreAudio rejected int32 PCM client format for \(targetPath) " +
            "(status \(formatOSStatus(int32ClientFormatStatus))); falling back to float32 PCM"
        )
        return .float32
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
        guard sourceExt == "flac" else {
            return
        }

        logger.debug("Metadata step: extracting tags from \(source.path)")
        let tags = try extractStandardTags(from: source, ffprobeURL: ffprobeURL)
        var atomicParsleyArgs = [target.path]

        appendAtomicParsleyTagArguments(from: tags, into: &atomicParsleyArgs)

        var temporaryArtworkURL: URL?
        let temporaryTaggedOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_to_aac_tagged_\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        if let ffmpegURL = ffmpegURL {
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

        atomicParsleyArgs.append(contentsOf: ["--output", temporaryTaggedOutputURL.path])

        defer {
            if let temporaryArtworkURL {
                try? FileManager.default.removeItem(at: temporaryArtworkURL)
            }
            try? FileManager.default.removeItem(at: temporaryTaggedOutputURL)
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

        guard FileManager.default.fileExists(atPath: temporaryTaggedOutputURL.path) else {
            throw CLIError("AtomicParsley did not produce output file at \(temporaryTaggedOutputURL.path)")
        }

        logger.debug("Metadata step: replacing target via temp-output path: \(temporaryTaggedOutputURL.path) -> \(target.path)")

        do {
            _ = try FileManager.default.replaceItemAt(
                target,
                withItemAt: temporaryTaggedOutputURL,
                backupItemName: nil,
                options: []
            )
        } catch {
            throw CLIError("Metadata retag output replace failed for \(target.path): \(error.localizedDescription)")
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
                let command = ([executableURL.path] + arguments).joined(separator: " ")
                throw CLIError("Timed out after \(Int(timeoutSeconds))s running command: \(command)")
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

    private static func loadAudioTracks(from asset: AVAsset) async throws -> [AVAssetTrack] {
        try await asset.loadTracks(withMediaType: .audio)
    }

    static func parseCommand(_ args: [String]) throws -> ParsedCommand {
        var debug = false
        var dryRun = false
        var explicitLRChannels = false
        var positional: [String] = []

        for arg in args {
            switch arg {
            case "-d":
                debug = true
            case "-n":
                dryRun = true
            case "--explicit-lr":
                explicitLRChannels = true
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
                explicitLRChannels: explicitLRChannels,
                sourceDirectory: positional[0],
                targetDirectory: positional[1]
            )
        )
    }

    static func usageText() -> String {
        """
        Usage: convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>

        Recursively scans <source_dir> for .flac, .aac, and .m4a files.
        .flac is converted to AAC (.m4a); .aac/.m4a are copied as-is.
        Metadata tags are transferred via ffprobe + AtomicParsley; artwork extraction uses ffmpeg.
        The directory structure is mirrored under <target_dir>/<source_dir_name>.

        Options:
          -d    Enable debug output
          -n    Dry run (show what would be converted)
          --explicit-lr  For multichannel FLAC, map only source channels 1/2 directly to L/R
          -h, --help    Show help
        """
    }

    static func shortUsageText() -> String {
        "Usage: convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>\nTry 'convert_to_aac -h' for more information.\n"
    }

    static func validateSourceAndTargetDirectories(sourceURL: URL, targetURL: URL) throws {
        let normalizedSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let normalizedTargetURL = targetURL.resolvingSymlinksInPath().standardizedFileURL

        let sourcePath = normalizedSourceURL.path
        let targetPath = normalizedTargetURL.path

        if sourcePath == targetPath {
            throw CLIError("Source and target directory must be different")
        }

        if isDirectoryOrDescendant(normalizedSourceURL, of: normalizedTargetURL) ||
            isDirectoryOrDescendant(normalizedTargetURL, of: normalizedSourceURL)
        {
            throw CLIError("Source and target directories must not contain each other")
        }
    }

    private static func isDirectoryOrDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentPath = parent.path
        let candidatePath = candidate.path
        return candidatePath.hasPrefix(parentPath + "/")
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
        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        guard let sourceFileName = relativeComponents.last else {
            throw CLIError("Failed to derive source file name from path: \(filePath)")
        }
        let normalizedDirectories = try relativeComponents.dropLast().map {
            try normalizedOutputPathComponentName($0, path: filePath)
        }

        let outputFileName: String
        switch action {
        case .convertToM4A:
            let sourceStem = (sourceFileName as NSString).deletingPathExtension
            let normalizedStem = try normalizedOutputPathComponentName(sourceStem, path: filePath)
            outputFileName = normalizedStem + ".m4a"
        case .copyAAC:
            outputFileName = try normalizedOutputPathComponentName(sourceFileName, path: filePath)
        }

        let normalizedSourceRootName = try normalizedOutputPathComponentName(
            sourceRoot.standardizedFileURL.lastPathComponent,
            path: sourcePath
        )
        var outputURL = targetRoot
            .standardizedFileURL
            .appendingPathComponent(normalizedSourceRootName)
        for directory in normalizedDirectories {
            outputURL.appendPathComponent(directory)
        }

        return outputURL.appendingPathComponent(outputFileName)
    }

    private static func normalizedOutputPathComponentName(_ name: String, path: String) throws -> String {
        let collapsed = name
            .split(whereSeparator: { scalar in
                scalar.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            })
            .joined(separator: " ")

        guard !collapsed.isEmpty else {
            throw CLIError("Output path component resolves to empty after whitespace normalization: \(path)")
        }

        return collapsed
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

    static func isFLACMetadataOutput(_ output: String) -> Bool {
        let normalized = output.lowercased()
        let hasDataFormat = normalized.contains("data format")
        let hasFLACMarker = normalized.contains("flac") || normalized.contains("fla c")
        return hasDataFormat && hasFLACMarker
    }

    static func hasAudioDataMetadata(_ output: String) -> Bool {
        let lines = output
            .lowercased()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        func firstNumericValue(in line: String) -> Double? {
            let pattern = #"-?[0-9]+(?:\.[0-9]+)?"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }

            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange),
                  let range = Range(match.range, in: line) else {
                return nil
            }

            return Double(line[range])
        }

        let durationLine = lines.first { $0.contains("estimated duration") || $0.contains("duration") }
        let audioByteCountLine = lines.first { $0.contains("audio data byte count") }

        let duration = durationLine.flatMap(firstNumericValue)
        let audioByteCount = audioByteCountLine.flatMap(firstNumericValue)

        if let duration, duration <= 0 {
            return false
        }

        if let audioByteCount, audioByteCount <= 0 {
            return false
        }

        return duration != nil || audioByteCount != nil
    }

    static func isValidAACFileWithAudioData(at fileURL: URL, logger: Logger) -> Bool {
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
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            guard isAACMetadataOutput(output) else {
                logger.debug("afinfo did not report AAC format for \(fileURL.path)")
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            guard hasAudioDataMetadata(output) else {
                logger.debug("afinfo did not report playable audio data for \(fileURL.path)")
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            return true
        } catch {
            logger.debug("Failed to run afinfo for \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }

    static func isValidFLACFileWithAudioData(at fileURL: URL, logger: Logger) -> Bool {
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
                logger.debug("afinfo reported non-FLAC or unreadable file: \(fileURL.path)")
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            guard isFLACMetadataOutput(output) else {
                logger.debug("afinfo did not report FLAC format for \(fileURL.path)")
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            guard hasAudioDataMetadata(output) else {
                logger.debug("afinfo did not report playable audio data for \(fileURL.path)")
                logger.debug("afinfo excerpt: \(afinfoExcerpt(output))")
                return false
            }

            return true
        } catch {
            logger.debug("Failed to run afinfo for \(fileURL.path): \(error.localizedDescription)")
            return false
        }
    }

    static func detailedErrorMessage(_ error: Error?) -> String {
        guard let error else {
            return "No detailed error was provided by AVFoundation."
        }

        let nsError = error as NSError
        let reason = nsError.localizedFailureReason ?? "No failure reason provided."
        var message = "\(nsError.localizedDescription) (domain=\(nsError.domain), code=\(nsError.code), reason=\(reason))"

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " underlying=(domain=\(underlying.domain), code=\(underlying.code)"
            if underlying.domain == NSOSStatusErrorDomain,
               let fourCC = osStatusFourCC(underlying.code) {
                message += ", fourCC='\(fourCC)'"
            }
            message += ")"
        }

        return message
    }

    static func afinfoExcerpt(_ output: String, maxLines: Int = 8) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .prefix(maxLines)
        if lines.isEmpty {
            return "<no afinfo output>"
        }
        return lines.joined(separator: " | ")
    }

    private static func logPostConversionLoudnessSanity(for target: URL, logger: Logger) async {
        do {
            let metrics = try await quickLoudnessMetrics(for: target)
            logger.debug(
                "FLAC post-conversion loudness check for \(target.lastPathComponent): " +
                "peak=\(String(format: "%.1f", metrics.peakDbFS)) dBFS, " +
                "rms=\(String(format: "%.1f", metrics.rmsDbFS)) dBFS, " +
                "samples=\(metrics.sampleCount)"
            )

            if isSuspiciouslyQuietLoudness(metrics: metrics) {
                logger.warning(
                    "Post-conversion loudness looks unusually low for \(target.path) " +
                    "(peak=\(String(format: "%.1f", metrics.peakDbFS)) dBFS, " +
                    "rms=\(String(format: "%.1f", metrics.rmsDbFS)) dBFS)."
                )
            }
        } catch {
            logger.warning("Post-conversion loudness check failed for \(target.path): \(error.localizedDescription)")
        }
    }

    private static func quickLoudnessMetrics(for fileURL: URL, sampleLimit: Int = 1_000_000) async throws -> LoudnessMetrics {
        let asset = AVURLAsset(url: fileURL)
        let audioTracks = try await loadAudioTracks(from: asset)
        guard let audioTrack = audioTracks.first else {
            throw CLIError("Loudness check failed: no audio track in \(fileURL.path)")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw CLIError("Loudness check failed: cannot start reading \(fileURL.path). \(detailedErrorMessage(error))")
        }

        var sampleCount = 0
        var peak: Double = 0
        var sumSquares: Double = 0

        while sampleCount < sampleLimit, let sampleBuffer = try await provider.next() {
            var bytes: Data?
            try sampleBuffer.withUnsafeSampleBuffer { rawBuffer in
                guard let blockBuffer = CMSampleBufferGetDataBuffer(rawBuffer) else {
                    return
                }

                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length >= MemoryLayout<Int16>.size else {
                    return
                }

                var localBytes = Data(count: length)
                try localBytes.withUnsafeMutableBytes { rawBytes in
                    guard let dst = rawBytes.baseAddress else {
                        throw CLIError("Loudness check failed: empty PCM buffer for \(fileURL.path)")
                    }
                    let status = CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: dst
                    )
                    guard status == kCMBlockBufferNoErr else {
                        throw CLIError("Loudness check failed: cannot read PCM bytes for \(fileURL.path), status \(status)")
                    }
                }

                bytes = localBytes
            }

            guard let bytes else {
                continue
            }

            bytes.withUnsafeBytes { rawBytes in
                let pcmSamples = rawBytes.bindMemory(to: Int16.self)
                for sample in pcmSamples {
                    if sampleCount >= sampleLimit {
                        break
                    }
                    let normalized = Double(abs(Int(sample))) / 32768.0
                    peak = max(peak, normalized)
                    sumSquares += normalized * normalized
                    sampleCount += 1
                }
            }
        }

        if reader.status == .failed {
            throw CLIError("Loudness check failed while reading \(fileURL.path). \(detailedErrorMessage(reader.error))")
        }
        guard sampleCount > 0 else {
            throw CLIError("Loudness check found no PCM samples in \(fileURL.path)")
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let peakDbFS = 20 * log10(max(peak, 1e-12))
        let rmsDbFS = 20 * log10(max(rms, 1e-12))
        return LoudnessMetrics(sampleCount: sampleCount, peakLinear: peak, rmsLinear: rms, peakDbFS: peakDbFS, rmsDbFS: rmsDbFS)
    }

    static func isSuspiciouslyQuietLoudness(metrics: LoudnessMetrics) -> Bool {
        if metrics.peakLinear <= 0.0001 {
            return true
        }
        return metrics.peakLinear <= 0.002 && metrics.rmsLinear <= 0.0003
    }

    static func osStatusFourCC(_ code: Int) -> String? {
        let ucode = UInt32(bitPattern: Int32(code))
        var chars: [UnicodeScalar] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            let value = UInt8((ucode >> UInt32(shift)) & 0xFF)
            guard value >= 32 && value <= 126 else {
                return nil
            }
            chars.append(UnicodeScalar(value))
        }
        return String(String.UnicodeScalarView(chars))
    }

    private static func checkOSStatus(_ status: OSStatus, context: String) throws {
        guard status == noErr else {
            let message = "\(context) failed with status \(formatOSStatus(status))"
            throw CLIError(message)
        }
    }

    private static func formatOSStatus(_ status: OSStatus) -> String {
        var message = "\(status)"
        if let fourCC = osStatusFourCC(Int(status)) {
            message += " ('\(fourCC)')"
        }
        return message
    }

    private static func pcmClientFormat(
        sampleRate: Double,
        channels: UInt32,
        sampleFormat: FLACEncoderClientSampleFormat
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = channels * UInt32(sampleFormat.bytesPerSample)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: sampleFormat.linearPCMFlags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static func aacEncodeSampleRateCandidates(sourceSampleRate: Double) -> [Double] {
        var candidates: [Double] = [sourceSampleRate]
        for fallback in [48_000.0, 44_100.0] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    private static let flacWriteCallback: FLAC__StreamDecoderWriteCallback = {
        decoder, framePointer, bufferPointer, clientData in
        guard let framePointer, let bufferPointer, let clientData else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        let state = Unmanaged<FLACDecoderState>.fromOpaque(clientData).takeUnretainedValue()
        let frame = framePointer.pointee
        let channels = Int(frame.header.channels)
        let blockSize = Int(frame.header.blocksize)

        guard channels > 0, blockSize > 0 else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        guard let encoder = state.encoder else {
            state.writeFailure = "FLAC encoder session not initialized"
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }
        let outputChannels = Int(encoder.channels)
        if outputChannels <= 0 {
            state.writeFailure = "FLAC encoder was configured with an invalid output channel count"
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }
        let bitsPerSample = Int(state.bitsPerSample ?? 32)
        let bytesPerSample = encoder.clientSampleFormat.bytesPerSample
        let bytesPerFrame = outputChannels * bytesPerSample
        var outputData = Data(count: blockSize * bytesPerFrame)
        let sourceChannelPointers = (0 ..< channels).map { bufferPointer[$0] }

        let filled = outputData.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let base = rawBytes.baseAddress else {
                return false
            }
            let outputInt32Samples = encoder.clientSampleFormat == .int32
                ? base.assumingMemoryBound(to: Int32.self)
                : nil
            let outputFloat32Samples = encoder.clientSampleFormat == .float32
                ? base.assumingMemoryBound(to: Float32.self)
                : nil
            let isDownmixingMultichannelToStereo = outputChannels == 2 && channels > 2 && !state.explicitLRChannels

            for sampleIndex in 0 ..< blockSize {
                var normalizedSamples: [Int32] = []
                normalizedSamples.reserveCapacity(channels)

                for channel in 0 ..< channels {
                    guard let channelPointer = sourceChannelPointers[channel] else {
                        state.writeFailure = "FLAC decode returned missing channel pointer at index \(channel)"
                        return false
                    }
                    let normalized = normalizeFLACSampleToPCM32(
                        channelPointer[sampleIndex],
                        bitsPerSample: bitsPerSample
                    )
                    normalizedSamples.append(normalized)
                }

                let frameStart = sampleIndex * outputChannels
                if outputChannels == 1 {
                    if let outputInt32Samples {
                        outputInt32Samples[frameStart] = normalizedSamples[0]
                    } else if let outputFloat32Samples {
                        outputFloat32Samples[frameStart] = pcm32DoubleToFloat32(Double(normalizedSamples[0]))
                    } else {
                        state.writeFailure = "FLAC encoder has no writable output sample buffer"
                        return false
                    }
                } else {
                    let stereo = downmixFLACSamplesToStereoDouble(
                        normalizedSamples: normalizedSamples,
                        explicitLRChannels: state.explicitLRChannels
                    )
                    let normalizedStereo = isDownmixingMultichannelToStereo
                        ? applyHeadroomAndLinearPeakScaling(stereoSample: stereo)
                        : stereo
                    if let outputInt32Samples {
                        outputInt32Samples[frameStart] = clampDoubleToInt32(normalizedStereo.left)
                        outputInt32Samples[frameStart + 1] = clampDoubleToInt32(normalizedStereo.right)
                    } else if let outputFloat32Samples {
                        outputFloat32Samples[frameStart] = pcm32DoubleToFloat32(normalizedStereo.left)
                        outputFloat32Samples[frameStart + 1] = pcm32DoubleToFloat32(normalizedStereo.right)
                    } else {
                        state.writeFailure = "FLAC encoder has no writable output sample buffer"
                        return false
                    }
                }
            }
            return true
        }
        guard filled else {
            if state.writeFailure == nil {
                state.writeFailure = "FLAC decode failed to prepare output buffer"
            }
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        let writeStatus = outputData.withUnsafeBytes { rawBytes -> OSStatus in
            let audioBuffer = AudioBuffer(
                mNumberChannels: encoder.channels,
                mDataByteSize: UInt32(outputData.count),
                mData: UnsafeMutableRawPointer(mutating: rawBytes.baseAddress)
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            return ExtAudioFileWrite(encoder.outputFile, UInt32(blockSize), &bufferList)
        }
        guard writeStatus == noErr else {
            var message = "ExtAudioFileWrite(\(encoder.targetPath)) failed with status \(writeStatus)"
            if let fourCC = osStatusFourCC(Int(writeStatus)) {
                message += " ('\(fourCC)')"
            }
            state.writeFailure = message
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        state.totalFrames += blockSize

        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    private static let flacMetadataCallback: FLAC__StreamDecoderMetadataCallback = {
        decoder, metadataPointer, clientData in
        guard let metadataPointer, let clientData else {
            return
        }

        let state = Unmanaged<FLACDecoderState>.fromOpaque(clientData).takeUnretainedValue()
        let metadata = metadataPointer.pointee
        guard metadata.type == FLAC__METADATA_TYPE_STREAMINFO else {
            return
        }

        let streamInfo = metadata.data.stream_info
        state.sampleRate = streamInfo.sample_rate
        state.sourceChannels = UInt32(max(Int(streamInfo.channels), 1))
        state.bitsPerSample = streamInfo.bits_per_sample
    }

    private static let flacErrorCallback: FLAC__StreamDecoderErrorCallback = {
        decoder, status, clientData in
        guard let clientData else {
            return
        }

        let state = Unmanaged<FLACDecoderState>.fromOpaque(clientData).takeUnretainedValue()
        state.decodeErrorMessages.append("FLAC decoder error status \(status.rawValue)")
    }

    static func normalizeFLACSampleToPCM32(_ sample: Int32, bitsPerSample: Int) -> Int32 {
        guard bitsPerSample > 0 else {
            return sample
        }

        if bitsPerSample < 32 {
            return sample << (32 - bitsPerSample)
        }

        if bitsPerSample > 32 {
            return sample >> (bitsPerSample - 32)
        }

        return sample
    }

    static func normalizedFLACOutputChannels(sourceChannels: UInt32, explicitLRChannels: Bool) -> UInt32 {
        if sourceChannels <= 1 {
            return 1
        }
        if explicitLRChannels {
            return 2
        }
        return min(sourceChannels, 2)
    }

    static func downmixFLACSamplesToStereo(
        normalizedSamples: [Int32],
        explicitLRChannels: Bool
    ) -> (left: Int32, right: Int32) {
        let stereo = downmixFLACSamplesToStereoDouble(
            normalizedSamples: normalizedSamples,
            explicitLRChannels: explicitLRChannels
        )
        return (clampDoubleToInt32(stereo.left), clampDoubleToInt32(stereo.right))
    }

    static func downmixFLACSamplesToStereoDouble(
        normalizedSamples: [Int32],
        explicitLRChannels: Bool
    ) -> (left: Double, right: Double) {
        if normalizedSamples.count == 1 {
            let mono = Double(normalizedSamples[0])
            return (mono, mono)
        }
        if explicitLRChannels || normalizedSamples.count == 2 {
            return (Double(normalizedSamples[0]), Double(normalizedSamples[1]))
        }

        var left = Double(normalizedSamples[0])
        var right = Double(normalizedSamples[1])

        if normalizedSamples.count > 2 {
            let center = Double(normalizedSamples[2]) * 0.707
            left += center
            right += center
        }
        if normalizedSamples.count > 3 {
            let lfe = Double(normalizedSamples[3]) * 0.5
            left += lfe
            right += lfe
        }
        if normalizedSamples.count > 4 { left += Double(normalizedSamples[4]) * 0.707 }
        if normalizedSamples.count > 5 { right += Double(normalizedSamples[5]) * 0.707 }
        if normalizedSamples.count > 6 { left += Double(normalizedSamples[6]) * 0.707 }
        if normalizedSamples.count > 7 { right += Double(normalizedSamples[7]) * 0.707 }

        if normalizedSamples.count > 8 {
            for index in 8 ..< normalizedSamples.count {
                let value = Double(normalizedSamples[index]) * 0.5
                if index.isMultiple(of: 2) {
                    left += value
                } else {
                    right += value
                }
            }
        }

        return (left, right)
    }

    static func applyHeadroomAndLinearPeakScaling(stereoSample: (left: Double, right: Double)) -> (left: Double, right: Double) {
        var left = stereoSample.left * downmixHeadroomGain
        var right = stereoSample.right * downmixHeadroomGain

        let peakMagnitude = max(abs(left), abs(right))
        let fullScale = Double(Int32.max)
        if peakMagnitude > fullScale {
            let scale = fullScale / peakMagnitude
            left *= scale
            right *= scale
        }

        return (left, right)
    }

    private static func clampDoubleToInt32(_ value: Double) -> Int32 {
        if value > Double(Int32.max) {
            return Int32.max
        }
        if value < Double(Int32.min) {
            return Int32.min
        }
        return Int32(value.rounded(.towardZero))
    }

    static func pcm32DoubleToFloat32(_ value: Double) -> Float32 {
        let clamped = max(Double(Int32.min), min(Double(Int32.max), value))
        return Float32(clamped / 2_147_483_648.0)
    }

    private static let downmixHeadroomGain: Double = 0.8912509381337456 // -1 dB

}

private final class FLACDecoderState {
    init(explicitLRChannels: Bool) {
        self.explicitLRChannels = explicitLRChannels
    }

    var sampleRate: UInt32?
    var sourceChannels: UInt32?
    var bitsPerSample: UInt32?
    var outputChannels: UInt32?
    var totalFrames: Int = 0
    var writeFailure: String?
    var decodeErrorMessages: [String] = []
    let explicitLRChannels: Bool
    var encoder: FLACEncoderSession?
}

private final class FLACEncoderSession {
    let outputFile: ExtAudioFileRef
    let targetPath: String
    let channels: UInt32
    let clientSampleFormat: FLACEncoderClientSampleFormat

    init(
        outputFile: ExtAudioFileRef,
        targetPath: String,
        channels: UInt32,
        clientSampleFormat: FLACEncoderClientSampleFormat
    ) {
        self.outputFile = outputFile
        self.targetPath = targetPath
        self.channels = channels
        self.clientSampleFormat = clientSampleFormat
    }

    deinit {
        ExtAudioFileDispose(outputFile)
    }
}

enum FLACEncoderClientSampleFormat {
    case int32
    case float32

    var bytesPerSample: Int {
        switch self {
        case .int32, .float32:
            return MemoryLayout<UInt32>.size
        }
    }

    var linearPCMFlags: AudioFormatFlags {
        switch self {
        case .int32:
            return kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        case .float32:
            return kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        }
    }
}

struct LoudnessMetrics {
    let sampleCount: Int
    let peakLinear: Double
    let rmsLinear: Double
    let peakDbFS: Double
    let rmsDbFS: Double
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
    let explicitLRChannels: Bool
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

enum AudioValidationError: Error, LocalizedError {
    case invalidSourceFLAC(path: String)
    case invalidConvertedM4A(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceFLAC(let path):
            return "Source FLAC file is invalid or has no audio data: \(path)"
        case .invalidConvertedM4A(let path):
            return "Converted file is not a valid AAC with audio data: \(path)"
        }
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
