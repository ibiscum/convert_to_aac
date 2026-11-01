import Foundation
import AVFoundation
import AudioToolbox
import CFLAC

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
                    logger.info("[dry-run] avfoundation-encode '\(fileURL.path)' -> '\(outputURL.path)'")
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
            } catch let validationError as AudioValidationError {
                throw CLIError(validationError.localizedDescription)
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
        logger.debug("Starting conversion: \(source.path) -> \(target.path)")

        let sourceExt = source.pathExtension.lowercased()
        if sourceExt == "flac" {
            guard isValidFLACFileWithAudioData(at: source, logger: logger) else {
                throw AudioValidationError.invalidSourceFLAC(path: source.path)
            }
        }

        do {
            if sourceExt == "flac" {
                try convertFLACToAACUsingLibFLAC(source: source, target: target, logger: logger)
            } else {
                try convertToAACUsingAVFoundation(source: source, target: target, logger: logger)
            }
        } catch {
            logger.error("Audio conversion failed for \(source.path): \(error.localizedDescription)")
            throw error
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

        guard isValidAACFileWithAudioData(at: target, logger: logger) else {
            throw AudioValidationError.invalidConvertedM4A(path: target.path)
        }
    }

    private static func convertToAACUsingAVFoundation(source: URL, target: URL, logger: Logger) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }

        let asset = AVURLAsset(url: source)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw CLIError("Source file has no audio track: \(source.path)")
        }
        logger.debug("Source track details for \(source.lastPathComponent): \(describeAudioTrack(audioTrack))")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(readerOutput) else {
            throw CLIError("AVFoundation reader could not attach audio output for \(source.path)")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: target, fileType: .m4a)
        let audioSettings = avFoundationAACOutputSettings(for: audioTrack)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw CLIError("AVFoundation writer could not attach AAC input for \(target.path)")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw CLIError(
                "AVFoundation failed to start writing \(target.path). \(detailedErrorMessage(writer.error))"
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw CLIError(
                "AVFoundation failed to start reading \(source.path). \(detailedErrorMessage(reader.error))"
            )
        }

        writer.startSession(atSourceTime: .zero)
        let conversionDeadline = Date().addingTimeInterval(300)
        var reachedEndOfInput = false

        while !reachedEndOfInput {
            if Date() > conversionDeadline {
                reader.cancelReading()
                writer.cancelWriting()
                throw CLIError("Timed out after 300s running AVFoundation conversion for \(source.path)")
            }

            if writerInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    if !writerInput.append(sampleBuffer) {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw CLIError(
                            "AVFoundation append failed for \(source.path). \(detailedErrorMessage(writer.error))"
                        )
                    }
                } else {
                    writerInput.markAsFinished()
                    reachedEndOfInput = true
                }
            } else {
                if reader.status == .failed {
                    writer.cancelWriting()
                    throw CLIError(
                        "AVFoundation read failed for \(source.path). \(detailedErrorMessage(reader.error))"
                    )
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishSemaphore.signal()
        }
        if finishSemaphore.wait(timeout: .now() + .seconds(300)) == .timedOut {
            writer.cancelWriting()
            throw CLIError("Timed out after 300s finalizing AVFoundation output for \(target.path)")
        }

        if reader.status == .failed {
            throw CLIError("AVFoundation read failed for \(source.path). \(detailedErrorMessage(reader.error))")
        }

        guard writer.status == .completed else {
            throw CLIError("AVFoundation write failed for \(target.path). \(detailedErrorMessage(writer.error))")
        }

        logger.debug("Running AVFoundation AAC encode (\(source.path) -> \(target.path)) with settings: \(audioSettings)")
    }

    private static func convertFLACToAACUsingLibFLAC(source: URL, target: URL, logger: Logger) throws {
        let decoded = try decodeFLACToPCM16(source: source, logger: logger)
        try encodePCM16ToM4AUsingCoreAudio(pcm: decoded, target: target)
        logger.debug(
            "Running libFLAC decode + CoreAudio AAC encode (\(source.path) -> \(target.path)); " +
            "sampleRate=\(decoded.sampleRate), channels=\(decoded.channels), frames=\(decoded.totalFrames)"
        )
    }

    private static func decodeFLACToPCM16(source: URL, logger: Logger) throws -> DecodedPCM16 {
        guard let decoder = FLAC__stream_decoder_new() else {
            throw CLIError("libFLAC failed to initialize decoder for \(source.path)")
        }
        defer {
            FLAC__stream_decoder_delete(decoder)
        }

        let state = FLACDecoderState()
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

        guard FLAC__stream_decoder_process_until_end_of_stream(decoder) != 0 else {
            throw CLIError("libFLAC failed while decoding \(source.path)")
        }

        guard let sampleRate = state.sampleRate, sampleRate > 0 else {
            throw CLIError("libFLAC did not report sample rate for \(source.path)")
        }
        guard let channels = state.channels, channels > 0 else {
            throw CLIError("libFLAC did not report channel count for \(source.path)")
        }

        if !state.decodeErrorMessages.isEmpty {
            logger.warning("libFLAC decode warnings for \(source.path): \(state.decodeErrorMessages.joined(separator: ", "))")
        }

        let bytesPerFrame = Int(channels) * MemoryLayout<Int16>.size
        let totalFrames = state.pcmData.count / bytesPerFrame
        guard totalFrames > 0 else {
            throw CLIError("libFLAC produced no PCM frames for \(source.path)")
        }

        return DecodedPCM16(
            sampleRate: Double(sampleRate),
            channels: channels,
            pcmData: state.pcmData,
            totalFrames: totalFrames
        )
    }

    private static func encodePCM16ToM4AUsingCoreAudio(pcm: DecodedPCM16, target: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }

        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let bytesPerFrame = pcm.channels * bytesPerSample

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: pcm.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: pcm.channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: pcm.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: pcm.channels,
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
        defer {
            ExtAudioFileDispose(outputFile)
        }

        try checkOSStatus(
            ExtAudioFileSetProperty(
                outputFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            ),
            context: "ExtAudioFileSetProperty(kExtAudioFileProperty_ClientDataFormat)"
        )

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

        let chunkFrames = 4096
        let totalFrames = pcm.totalFrames
        let bytesPerFrameInt = Int(bytesPerFrame)

        try pcm.pcmData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw CLIError("Decoded PCM buffer is empty")
            }

            var frameOffset = 0
            while frameOffset < totalFrames {
                let framesToWrite = min(chunkFrames, totalFrames - frameOffset)
                let byteOffset = frameOffset * bytesPerFrameInt
                let byteCount = framesToWrite * bytesPerFrameInt
                let chunkPointer = baseAddress.advanced(by: byteOffset)

                let audioBuffer = AudioBuffer(
                    mNumberChannels: pcm.channels,
                    mDataByteSize: UInt32(byteCount),
                    mData: UnsafeMutableRawPointer(mutating: chunkPointer)
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                try checkOSStatus(
                    ExtAudioFileWrite(outputFile, UInt32(framesToWrite), &bufferList),
                    context: "ExtAudioFileWrite(\(target.path))"
                )

                frameOffset += framesToWrite
            }
        }
    }

    private static func avFoundationAACOutputSettings(for track: AVAssetTrack) -> [String: Any] {
        var sampleRate: Double = 44_100
        var channels = 2

        for formatDescription in track.formatDescriptions {
            let audioFormat = formatDescription as! CMAudioFormatDescription
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?
                    .pointee else {
                continue
            }

            if streamDescription.mSampleRate > 0 {
                sampleRate = streamDescription.mSampleRate
            }
            if streamDescription.mChannelsPerFrame > 0 {
                channels = Int(streamDescription.mChannelsPerFrame)
            }
            break
        }

        let normalizedChannels = min(max(channels, 1), 2)

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: 256_000,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: normalizedChannels,
        ]
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
        let temporaryTaggedOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("convert_to_aac_tagged_\(UUID().uuidString)")
            .appendingPathExtension("m4a")
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
        The directory structure is mirrored under <target_dir>/<source_dir_name>.

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
        let sourceRootName = sourceRoot.standardizedFileURL.lastPathComponent
        return targetRoot
            .standardizedFileURL
            .appendingPathComponent(sourceRootName)
            .appendingPathComponent(outputRelative)
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

    static func describeAudioTrack(_ track: AVAssetTrack) -> String {
        for formatDescription in track.formatDescriptions {
            let audioFormat = formatDescription as! CMAudioFormatDescription
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
            else {
                continue
            }

            return "sampleRate=\(streamDescription.mSampleRate), channels=\(streamDescription.mChannelsPerFrame), formatID=\(streamDescription.mFormatID)"
        }

        return "sampleRate=unknown, channels=unknown, formatID=unknown"
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
            var message = "\(context) failed with status \(status)"
            if let fourCC = osStatusFourCC(Int(status)) {
                message += " ('\(fourCC)')"
            }
            throw CLIError(message)
        }
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

        let outputChannels = min(channels, Int(state.channels ?? UInt32(channels)))
        if outputChannels <= 0 {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        state.pcmData.reserveCapacity(state.pcmData.count + blockSize * outputChannels * MemoryLayout<Int16>.size)

        for sampleIndex in 0 ..< blockSize {
            for channel in 0 ..< outputChannels {
                guard let channelPointer = bufferPointer[channel] else {
                    return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
                }
                let sample32 = channelPointer[sampleIndex]
                let clipped = max(Int32(Int16.min), min(Int32(Int16.max), sample32))
                var sample16 = Int16(clipped)
                withUnsafeBytes(of: &sample16) { bytes in
                    state.pcmData.append(contentsOf: bytes)
                }
            }
        }

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
        state.channels = UInt32(min(max(Int(streamInfo.channels), 1), 2))
    }

    private static let flacErrorCallback: FLAC__StreamDecoderErrorCallback = {
        decoder, status, clientData in
        guard let clientData else {
            return
        }

        let state = Unmanaged<FLACDecoderState>.fromOpaque(clientData).takeUnretainedValue()
        state.decodeErrorMessages.append("FLAC decoder error status \(status.rawValue)")
    }
}

private final class FLACDecoderState {
    var sampleRate: UInt32?
    var channels: UInt32?
    var pcmData = Data()
    var decodeErrorMessages: [String] = []
}

private struct DecodedPCM16 {
    let sampleRate: Double
    let channels: UInt32
    let pcmData: Data
    let totalFrames: Int
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
