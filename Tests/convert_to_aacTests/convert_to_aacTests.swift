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
        #expect(output.path == "/output/artist/album/track01.m4a")
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
        #expect(output.path == "/output/artist/album/track01.aac")
    }

@Test func outputURLRejectsFilesOutsideSourceRoot() {
        let sourceRoot = URL(fileURLWithPath: "/input")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/elsewhere/track.mp3")

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
        #expect(ConvertToAAC.sourceAction(forExtension: "mp3") == .convertToM4A)
        #expect(ConvertToAAC.sourceAction(forExtension: "FLAC") == .convertToM4A)
        #expect(ConvertToAAC.sourceAction(forExtension: "aac") == .copyAAC)
        #expect(ConvertToAAC.sourceAction(forExtension: "M4A") == .copyAAC)
        #expect(ConvertToAAC.sourceAction(forExtension: "wav") == nil)
    }

@Test func usageTextRegression() {
        let usage = ConvertToAAC.usageText()
        #expect(usage.contains("Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>"))
        #expect(usage.contains("-d    Enable debug output"))
        #expect(usage.contains("-n    Dry run (show what would be converted)"))
        #expect(usage.contains("-h    Show help"))
    }

@Test func shortUsageRegression() {
        let shortUsage = ConvertToAAC.shortUsageText()
        #expect(shortUsage == "Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>\nTry 'convert_to_aac -h' for more information.\n")
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
        #expect(stderrText.contains("Usage: convert_to_aac [-d] [-n] <source_dir> <target_dir>"))
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
