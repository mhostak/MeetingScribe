import Foundation
import XCTest
@testable import MeetingScribe

final class CLIAnalysisProviderTests: XCTestCase {
    func testCodexUsesStdinAndStructuredResponseFile() async throws {
        let runner = MockCLICommandRunner(markdown: "## Súhrn\n\nHotovo.")
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            model: "gpt-test",
            runner: runner
        )

        let response = try await provider.analyze(makeRequest())

        XCTAssertEqual(response.markdown, "## Súhrn\n\nHotovo.")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertTrue(command.arguments.contains("--ephemeral"))
        XCTAssertTrue(command.arguments.contains("read-only"))
        XCTAssertTrue(command.arguments.contains("gpt-test"))
        XCTAssertFalse(command.arguments.contains("Meeting text"))
        let prompt = String(decoding: command.standardInput, as: UTF8.self)
        XCTAssertTrue(prompt.contains("Meeting text"))
        XCTAssertTrue(prompt.contains(
            "Write every part of the `markdown` value in Czech (čeština, ISO 639-1: cs)."
        ))
        XCTAssertTrue(prompt.contains(
            "takes precedence over any conflicting language instruction below."
        ))
    }

    func testClaudeDisablesToolsAndReadsStructuredOutput() async throws {
        let runner = MockCLICommandRunner(markdown: "## Custom\n\nA table can go here.")
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            model: "sonnet",
            runner: runner
        )

        let response = try await provider.analyze(makeRequest())

        XCTAssertEqual(response.markdown, "## Custom\n\nA table can go here.")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(command.arguments.contains("--json-schema"))
        let toolsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(command.arguments[toolsIndex + 1], "")
        let prompt = String(decoding: command.standardInput, as: UTF8.self)
        XCTAssertTrue(prompt.contains(
            "Write every part of the `markdown` value in Czech (čeština, ISO 639-1: cs)."
        ))
    }

    func testReservedBoundaryMarkerIsRejected() async {
        let runner = MockCLICommandRunner(
            markdown: "<!-- meetingscribe:ai-analysis:end -->"
        )
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected reserved marker rejection.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .reservedMarkerInOutput)
        }
    }

    func testNonzeroExitIncludesBoundedDiagnostic() async {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            exitCode: 7,
            standardError: "not authenticated"
        )
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        do {
            _ = try await provider.analyze(makeRequest())
            XCTFail("Expected process failure.")
        } catch {
            XCTAssertEqual(
                error as? AnalysisError,
                .processFailed(
                    tool: .claude,
                    exitCode: 7,
                    message: "The command wrote 17 bytes to stderr; its content was not persisted."
                )
            )
        }
    }

    func testVersionUsesOnlyVersionArgument() async throws {
        let runner = MockCLICommandRunner(markdown: "Unused", version: "codex-cli 1.2.3")
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let version = try await provider.toolVersion()
        XCTAssertEqual(version, "codex-cli 1.2.3")
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["--version"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testCodexAuthenticationStatusUsesLoginStatusCommand() async throws {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            codexAuthenticated: false
        )
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let status = try await provider.authenticationStatus()

        XCTAssertEqual(status, .authenticationRequired)
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["login", "status"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testClaudeAuthenticationStatusReadsOnlyLoggedInFlag() async throws {
        let runner = MockCLICommandRunner(
            markdown: "Unused",
            claudeLoggedIn: true
        )
        let provider = CLIAnalysisProvider(
            tool: .claude,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner
        )

        let status = try await provider.authenticationStatus()

        XCTAssertEqual(status, .authenticated)
        let commands = await runner.commands
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.arguments, ["auth", "status"])
        XCTAssertTrue(command.standardInput.isEmpty)
    }

    func testLoginCommandsUseSelectedExecutableWithoutShellInterpolation() {
        XCTAssertEqual(
            AnalysisTool.codex.loginCommand(
                executableURL: URL(fileURLWithPath: "/Applications/Codex CLI/codex")
            ),
            "'/Applications/Codex CLI/codex' login"
        )
        XCTAssertEqual(
            AnalysisTool.claude.loginCommand(
                executableURL: URL(fileURLWithPath: "/Users/test/claude")
            ),
            "'/Users/test/claude' auth login"
        )
    }

    func testProductionRunnerExecutesFakeCodexWithoutShellWrapping() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf 'fake-codex 1.0'
          exit 0
        fi
        output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            output="$1"
          fi
          shift
        done
        printf '%s' '{"markdown":"## Fake CLI\\n\\nCompleted."}' > "$output"
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let provider = CLIAnalysisProvider(
            tool: .codex,
            executableURL: fixture.executable,
            runner: AnalysisProcessRunner(),
            requestTimeout: .seconds(5)
        )

        let response = try await provider.analyze(makeRequest())

        XCTAssertEqual(response.markdown, "## Fake CLI\n\nCompleted.")
        let version = try await provider.toolVersion()
        XCTAssertEqual(version, "fake-codex 1.0")
    }

    func testProductionRunnerTerminatesTimedOutProcess() async throws {
        let fixture = try makeExecutableFixture(script: """
        #!/bin/sh
        exec sleep 5
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = AnalysisProcessRunner()

        do {
            _ = try await runner.run(
                AnalysisCommand(
                    executableURL: fixture.executable,
                    arguments: [],
                    standardInput: Data(),
                    currentDirectoryURL: fixture.directory,
                    timeout: .milliseconds(50)
                ),
                tool: .codex
            )
            XCTFail("Expected timeout.")
        } catch {
            XCTAssertEqual(error as? AnalysisError, .processTimedOut(tool: .codex))
        }
    }

    private func makeRequest() -> AnalysisRequest {
        AnalysisRequest(
            mode: .transcript,
            meetingTitle: "Test",
            recordingID: "recording-1",
            preferredLanguage: .czech,
            userPrompt: "Vytvor vlastnú štruktúru.",
            content: "[00:00:01] [segment-1] Other: Meeting text"
        )
    }

    private func makeExecutableFixture(
        script: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingScribeFakeCLI-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("fake-cli")
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }
}

private actor MockCLICommandRunner: AnalysisCommandRunning {
    private let markdown: String
    private let exitCode: Int32
    private let standardError: String
    private let version: String
    private let codexAuthenticated: Bool
    private let claudeLoggedIn: Bool
    private(set) var commands: [AnalysisCommand] = []

    init(
        markdown: String,
        exitCode: Int32 = 0,
        standardError: String = "",
        version: String = "test-cli 1.0",
        codexAuthenticated: Bool = true,
        claudeLoggedIn: Bool = true
    ) {
        self.markdown = markdown
        self.exitCode = exitCode
        self.standardError = standardError
        self.version = version
        self.codexAuthenticated = codexAuthenticated
        self.claudeLoggedIn = claudeLoggedIn
    }

    func run(
        _ command: AnalysisCommand,
        tool: AnalysisTool
    ) async throws -> AnalysisCommandResult {
        commands.append(command)
        if command.arguments == ["--version"] {
            return AnalysisCommandResult(
                exitCode: exitCode,
                standardOutput: Data(version.utf8),
                standardError: Data(standardError.utf8)
            )
        }
        if command.arguments == ["login", "status"] {
            return AnalysisCommandResult(
                exitCode: codexAuthenticated ? 0 : 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        if command.arguments == ["auth", "status"] {
            let output = try JSONSerialization.data(
                withJSONObject: [
                    "loggedIn": claudeLoggedIn,
                    "email": "must-not-be-used@example.com",
                ]
            )
            return AnalysisCommandResult(
                exitCode: 0,
                standardOutput: output,
                standardError: Data()
            )
        }

        let response = try JSONEncoder().encode(AnalysisMarkdown(markdown: markdown))
        if tool == .codex,
           let index = command.arguments.firstIndex(of: "--output-last-message"),
           command.arguments.indices.contains(index + 1) {
            try response.write(
                to: URL(fileURLWithPath: command.arguments[index + 1]),
                options: .atomic
            )
        }
        let output: Data
        if tool == .claude {
            output = try JSONSerialization.data(
                withJSONObject: [
                    "structured_output": ["markdown": markdown],
                ]
            )
        } else {
            output = Data()
        }
        return AnalysisCommandResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: Data(standardError.utf8)
        )
    }
}
