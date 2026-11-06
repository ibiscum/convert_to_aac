import Testing
import Foundation
@testable import convert_to_aac

@Test func parseCommandParsesFlagsAndArguments() throws {
        let command = try ConvertToAAC.parseCommand(["-d", "-n", "/music/src", "/music/out"])

        switch command {
        case .help:
            Issue.record("Expected .run command")
        case .run(let config):
            #expect(config.debug == true)
            #expect(config.dryRun == true)
            #expect(config.explicitLRChannels == false)
            #expect(config.sourceDirectory == "/music/src")
            #expect(config.targetDirectory == "/music/out")
        }
    }

@Test func parseCommandParsesExplicitLROption() throws {
    let command = try ConvertToAAC.parseCommand(["--explicit-lr", "/music/src", "/music/out"])

    switch command {
    case .help:
        Issue.record("Expected .run command")
    case .run(let config):
        #expect(config.explicitLRChannels == true)
        #expect(config.sourceDirectory == "/music/src")
        #expect(config.targetDirectory == "/music/out")
    }
}

@Test func parseCommandReturnsHelpForHelpFlags() throws {
        let shortHelp = try ConvertToAAC.parseCommand(["-h"])
        let longHelp = try ConvertToAAC.parseCommand(["--help"])

        switch shortHelp {
        case .help:
            break
        case .run:
            Issue.record("Expected .help for -h")
        }

        switch longHelp {
        case .help:
            break
        case .run:
            Issue.record("Expected .help for --help")
        }
    }

@Test func parseCommandThrowsOnUnknownOption() {
        #expect(throws: CLIError.self) {
            _ = try ConvertToAAC.parseCommand(["--unknown", "/src", "/dst"])
        }
    }

@Test func parseCommandThrowsOnMissingArguments() {
        #expect(throws: CLIError.self) {
            _ = try ConvertToAAC.parseCommand(["-d", "/src"])
        }
    }

@Test func validateSourceAndTargetDirectoriesRejectsSameDirectory() {
    let source = URL(fileURLWithPath: "/music/library")
    let target = URL(fileURLWithPath: "/music/library")

    #expect(throws: CLIError.self) {
        try ConvertToAAC.validateSourceAndTargetDirectories(sourceURL: source, targetURL: target)
    }
}

@Test func validateSourceAndTargetDirectoriesRejectsTargetInsideSource() {
    let source = URL(fileURLWithPath: "/music/library")
    let target = URL(fileURLWithPath: "/music/library/aac")

    #expect(throws: CLIError.self) {
        try ConvertToAAC.validateSourceAndTargetDirectories(sourceURL: source, targetURL: target)
    }
}

@Test func validateSourceAndTargetDirectoriesRejectsSourceInsideTarget() {
    let source = URL(fileURLWithPath: "/music/library/source")
    let target = URL(fileURLWithPath: "/music/library")

    #expect(throws: CLIError.self) {
        try ConvertToAAC.validateSourceAndTargetDirectories(sourceURL: source, targetURL: target)
    }
}

@Test func validateSourceAndTargetDirectoriesAcceptsDisjointDirectories() throws {
    let source = URL(fileURLWithPath: "/music/source")
    let target = URL(fileURLWithPath: "/music/output")

    try ConvertToAAC.validateSourceAndTargetDirectories(sourceURL: source, targetURL: target)
}

@Test func outputURLMirrorsStructureAndChangesExtension() throws {
        let sourceRoot = URL(fileURLWithPath: "/input")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/input/artist/album/track01.flac")

        let output = try ConvertToAAC.outputURL(
            for: inputFile,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            action: .convertToM4A
        )
        #expect(output.path == "/output/input/artist/album/track01.m4a")
    }

@Test func outputURLMirrorsStructureForCopyAAC() throws {
        let sourceRoot = URL(fileURLWithPath: "/input")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/input/artist/album/track01.aac")

        let output = try ConvertToAAC.outputURL(
            for: inputFile,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            action: .copyAAC
        )
        #expect(output.path == "/output/input/artist/album/track01.aac")
    }

@Test func outputURLNormalizesSpacesInFolderAndFileNamesForConversion() throws {
        let sourceRoot = URL(fileURLWithPath: "/input   root ")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/input   root / artist   name / album   one /  track   01 .flac")

        let output = try ConvertToAAC.outputURL(
            for: inputFile,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            action: .convertToM4A
        )
        #expect(output.path == "/output/input root/artist name/album one/track 01.m4a")
    }

@Test func outputURLNormalizesSpacesInFolderAndFileNamesForCopy() throws {
        let sourceRoot = URL(fileURLWithPath: "/input   root ")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/input   root / artist   name / album   one /  track   01 .aac")

        let output = try ConvertToAAC.outputURL(
            for: inputFile,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            action: .copyAAC
        )
        #expect(output.path == "/output/input root/artist name/album one/track 01 .aac")
    }

@Test func outputURLRejectsFilesOutsideSourceRoot() {
        let sourceRoot = URL(fileURLWithPath: "/input")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/elsewhere/track.flac")

        #expect(throws: CLIError.self) {
            _ = try ConvertToAAC.outputURL(
                for: inputFile,
                sourceRoot: sourceRoot,
                targetRoot: targetRoot,
                action: .convertToM4A
            )
        }
    }

@Test func sourceActionClassifiesExtensions() {
        #expect(ConvertToAAC.sourceAction(forExtension: "FLAC") == .convertToM4A)
        #expect(ConvertToAAC.sourceAction(forExtension: "mp3") == nil)
        #expect(ConvertToAAC.sourceAction(forExtension: "aac") == .copyAAC)
        #expect(ConvertToAAC.sourceAction(forExtension: "M4A") == .copyAAC)
        #expect(ConvertToAAC.sourceAction(forExtension: "wav") == nil)
    }

@Test func usageTextRegression() {
        let usage = ConvertToAAC.usageText()
        #expect(usage.contains("Usage: convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>"))
        #expect(usage.contains("-d    Enable debug output"))
        #expect(usage.contains("-n    Dry run (show what would be converted)"))
        #expect(usage.contains("--explicit-lr  For multichannel FLAC, map only source channels 1/2 directly to L/R"))
        #expect(usage.contains("-h, --help    Show help"))
    }

@Test func shortUsageRegression() {
        let shortUsage = ConvertToAAC.shortUsageText()
        #expect(shortUsage == "Usage: convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>\nTry 'convert_to_aac -h' for more information.\n")
    }

@Test func shouldSkipConversionFalseWhenTargetDoesNotExist() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let target = tempDir.appendingPathComponent("missing.m4a")

        let shouldSkip = ConvertToAAC.shouldSkipConversion(targetURL: target) { _ in true }
        #expect(shouldSkip == false)
    }

@Test func shouldSkipConversionDoesNotCallValidatorWhenTargetDoesNotExist() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let target = tempDir.appendingPathComponent("missing.m4a")
        var validatorCallCount = 0

        let shouldSkip = ConvertToAAC.shouldSkipConversion(targetURL: target) { _ in
            validatorCallCount += 1
            return true
        }

        #expect(shouldSkip == false)
        #expect(validatorCallCount == 0)
    }

@Test func shouldSkipConversionTrueWhenTargetExistsAndValidatorAcceptsAAC() throws {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("existing.m4a")
        try Data("placeholder".utf8).write(to: target)

        let shouldSkip = ConvertToAAC.shouldSkipConversion(targetURL: target) { _ in true }
        #expect(shouldSkip == true)
    }

@Test func shouldSkipConversionFalseWhenTargetExistsButValidatorRejectsAAC() throws {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("existing.m4a")
        try Data("placeholder".utf8).write(to: target)

        let shouldSkip = ConvertToAAC.shouldSkipConversion(targetURL: target) { _ in false }
        #expect(shouldSkip == false)
    }

@Test func shouldSkipConversionCallsValidatorOnceWhenTargetExists() throws {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("existing.m4a")
        try Data("placeholder".utf8).write(to: target)
        var validatorCallCount = 0

        let shouldSkip = ConvertToAAC.shouldSkipConversion(targetURL: target) { _ in
            validatorCallCount += 1
            return false
        }

        #expect(shouldSkip == false)
        #expect(validatorCallCount == 1)
    }

@Test func isAACMetadataOutputRegression() {
        let validOutput = """
        File: /tmp/sample.m4a
        File type ID: m4af
        Data format: 2 ch, 44100 Hz, 'aac ' (0x00000000) 0 bits/channel, 0 bytes/packet, 1024 frames/packet, 0 bytes/frame
        """

        let invalidOutput = """
        File: /tmp/sample.wav
        Data format: 2 ch, 44100 Hz, 'lpcm' (0x00000000)
        """

        #expect(ConvertToAAC.isAACMetadataOutput(validOutput) == true)
        #expect(ConvertToAAC.isAACMetadataOutput(invalidOutput) == false)
        #expect(ConvertToAAC.isAACMetadataOutput("not an afinfo output") == false)
    }

@Test func isFLACMetadataOutputRegression() {
        let validOutput = """
        File: /tmp/sample.flac
        File type ID: flac
        Data format: 2 ch, 44100 Hz, 'flac' (0x00000000)
        """

        let invalidOutput = """
        File: /tmp/sample.wav
        Data format: 2 ch, 44100 Hz, 'lpcm' (0x00000000)
        """

        #expect(ConvertToAAC.isFLACMetadataOutput(validOutput) == true)
        #expect(ConvertToAAC.isFLACMetadataOutput(invalidOutput) == false)
        #expect(ConvertToAAC.isFLACMetadataOutput("not an afinfo output") == false)
    }

@Test func hasAudioDataMetadataAcceptsPositiveDurationAndByteCount() {
        let output = """
        File: /tmp/sample.m4a
        estimated duration: 217.147755 sec
        audio data byte count: 6929518
        """

        #expect(ConvertToAAC.hasAudioDataMetadata(output) == true)
    }

@Test func hasAudioDataMetadataRejectsZeroDuration() {
        let output = """
        File: /tmp/sample.m4a
        estimated duration: 0.000000 sec
        audio data byte count: 6929518
        """

        #expect(ConvertToAAC.hasAudioDataMetadata(output) == false)
    }

@Test func hasAudioDataMetadataRejectsMissingAudioIndicators() {
        let output = """
        File: /tmp/sample.m4a
        File type ID: m4af
        Data format: 2 ch, 44100 Hz, 'aac ' (0x00000000)
        """

        #expect(ConvertToAAC.hasAudioDataMetadata(output) == false)
    }

@Test func integrationMissingArgumentsPrintsErrorAndUsageToStderr() throws {
        let executableURL = try builtExecutableURL(named: "convert_to_aac")
        let process = Process()
        process.executableURL = executableURL

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(stderrText.contains("Error: Expected exactly 2 arguments: <source_dir> <target_dir>"))
        #expect(stderrText.contains("Usage: convert_to_aac [-d] [-n] [--explicit-lr] <source_dir> <target_dir>"))
        #expect(stderrText.contains("Try 'convert_to_aac -h' for more information."))
    }

@Test func findExecutableLocatesKnownSystemBinary() {
    let url = ConvertToAAC.findExecutable(named: "swift")
    #expect(url != nil)
}

@Test func findExecutableReturnsNilForNonExistentBinary() {
    let url = ConvertToAAC.findExecutable(named: "this-binary-does-not-exist-12345")
    #expect(url == nil)
}

@Test func audioValidationErrorDescriptionsRegression() {
    let invalidFlac = AudioValidationError.invalidSourceFLAC(path: "/tmp/a.flac")
    let invalidM4A = AudioValidationError.invalidConvertedM4A(path: "/tmp/a.m4a")

    #expect(invalidFlac.localizedDescription.contains("invalid or has no audio data"))
    #expect(invalidM4A.localizedDescription.contains("not a valid AAC with audio data"))
}

@Test func normalizeFLACSampleToPCM32Scales24BitToFullInt32Range() {
    let positive24Bit = Int32(8_388_607)
    let negative24Bit = Int32(-8_388_608)

    #expect(ConvertToAAC.normalizeFLACSampleToPCM32(positive24Bit, bitsPerSample: 24) == 2_147_483_392)
    #expect(ConvertToAAC.normalizeFLACSampleToPCM32(negative24Bit, bitsPerSample: 24) == Int32.min)
}

@Test func normalizeFLACSampleToPCM32Scales16BitToFullInt32Range() {
    let positive16Bit = Int32(32_767)
    let negative16Bit = Int32(-32_768)

    #expect(ConvertToAAC.normalizeFLACSampleToPCM32(positive16Bit, bitsPerSample: 16) == 2_147_418_112)
    #expect(ConvertToAAC.normalizeFLACSampleToPCM32(negative16Bit, bitsPerSample: 16) == Int32.min)
}

@Test func isSuspiciouslyQuietLoudnessDetectsNearSilence() {
    let nearSilent = LoudnessMetrics(
        sampleCount: 10_000,
        peakLinear: 0.00005,
        rmsLinear: 0.00001,
        peakDbFS: -86.0,
        rmsDbFS: -100.0
    )

    #expect(ConvertToAAC.isSuspiciouslyQuietLoudness(metrics: nearSilent) == true)
}

@Test func isSuspiciouslyQuietLoudnessAcceptsNormalProgramMaterial() {
    let normal = LoudnessMetrics(
        sampleCount: 10_000,
        peakLinear: 0.65,
        rmsLinear: 0.12,
        peakDbFS: -3.7,
        rmsDbFS: -18.4
    )

    #expect(ConvertToAAC.isSuspiciouslyQuietLoudness(metrics: normal) == false)
}

@Test func normalizedFLACOutputChannelsRespectsExplicitLROption() {
    #expect(ConvertToAAC.normalizedFLACOutputChannels(sourceChannels: 1, explicitLRChannels: false) == 1)
    #expect(ConvertToAAC.normalizedFLACOutputChannels(sourceChannels: 6, explicitLRChannels: false) == 2)
    #expect(ConvertToAAC.normalizedFLACOutputChannels(sourceChannels: 6, explicitLRChannels: true) == 2)
}

@Test func downmixFLACSamplesToStereoUsesExplicitLRWhenEnabled() {
    let channels: [Int32] = [100, 200, 5_000, 7_000, 9_000, 11_000]
    let explicit = ConvertToAAC.downmixFLACSamplesToStereo(normalizedSamples: channels, explicitLRChannels: true)
    #expect(explicit.left == 100)
    #expect(explicit.right == 200)
}

private func builtExecutableURL(named executableName: String) throws -> URL {
    let testBundleURL = URL(fileURLWithPath: #filePath)
    let testsDirectory = testBundleURL.deletingLastPathComponent()
    let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let buildDir = packageRoot.appendingPathComponent(".build")

    let candidates = [
        buildDir.appendingPathComponent("debug/\(executableName)"),
        buildDir.appendingPathComponent("arm64-apple-macosx/debug/\(executableName)"),
        buildDir.appendingPathComponent("x86_64-apple-macosx/debug/\(executableName)"),
    ]

    let fileManager = FileManager.default
    if let existing = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
        return existing
    }

    throw CLIError("Could not locate built executable at expected paths under \(buildDir.path)")
}
