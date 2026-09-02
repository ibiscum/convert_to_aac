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

        let output = try ConvertToAAC.outputURL(for: inputFile, sourceRoot: sourceRoot, targetRoot: targetRoot)
        #expect(output.path == "/output/artist/album/track01.m4a")
    }

@Test func outputURLRejectsFilesOutsideSourceRoot() {
        let sourceRoot = URL(fileURLWithPath: "/input")
        let targetRoot = URL(fileURLWithPath: "/output")
        let inputFile = URL(fileURLWithPath: "/elsewhere/track.mp3")

        #expect(throws: CLIError.self) {
            _ = try ConvertToAAC.outputURL(for: inputFile, sourceRoot: sourceRoot, targetRoot: targetRoot)
        }
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
