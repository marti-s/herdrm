#if os(macOS)
import Foundation
import XCTest
@testable import HerdrKit

final class PiCompatibleLaunchTests: XCTestCase {
    func testPiShimRunsBinaryAsChildWithOriginalArgumentsWithoutFollowingOldSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let shimDirectory = directory.appendingPathComponent("herdrm-agent-shims", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("symlink-target")
        try "original target".write(to: target, atomically: true, encoding: .utf8)
        let shim = shimDirectory.appendingPathComponent("pi")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: target)
        let fake = bin.appendingPathComponent("atomic")
        let source = directory.appendingPathComponent("atomic.c")
        try #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            FILE *args = fopen(getenv("CAPTURE_ARGS"), "w");
            for (int i = 1; i < argc; i++) fprintf(args, "%s\n", argv[i]);
            fclose(args);
            char command[4096];
            snprintf(command, sizeof(command), "/bin/ps -p %d -o command= > %s", getppid(), getenv("CAPTURE_PARENT"));
            return system(command);
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", fake.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let argsFile = directory.appendingPathComponent("args")
        let parentFile = directory.appendingPathComponent("parent")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: "atomic", args: ["space value", "it's quoted"])]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(bin.path):/usr/bin:/bin",
            "TMPDIR": directory.path,
            "CAPTURE_ARGS": argsFile.path,
            "CAPTURE_PARENT": parentFile.path,
        ]) { _, value in value }
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: shim.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original target")
        XCTAssertEqual(try String(contentsOf: argsFile, encoding: .utf8), "space value\nit's quoted\n")
        let parentCommand = try String(contentsOf: parentFile, encoding: .utf8)
        XCTAssertTrue(parentCommand.contains("/herdrm-agent-shims."))
        XCTAssertTrue(parentCommand.contains("/pi"))
        XCTAssertFalse(parentCommand.contains("atomic_binary="))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("herdrm-agent-shims.") })
    }

    func testShimIsRemovedWithoutInstallingExitTrapWhilePaneShellContinues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-atomic")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let check = """
        shim_exists=no; for shim in "$TMPDIR"/herdrm-agent-shims.*; do
            if [ -d "$shim" ]; then shim_exists=yes; fi
        done
        printf 'SHIM_DIR_EXISTS=%s\\n' "$shim_exists"
        traps=$(trap)
        if [ -z "$traps" ]; then exit_trap_set=no; else exit_trap_set=yes; fi
        printf 'EXIT_TRAP_SET=%s\\nTRAPS=%s\\n' "$exit_trap_set" "$traps"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: binary.path, args: []) + "; " + check]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/usr/bin:/bin", "TMPDIR": directory.path,
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(text, "SHIM_DIR_EXISTS=no\nEXIT_TRAP_SET=no\nTRAPS=\n")
    }

    func testLaunchUsesFreshShimDirectoryThatIsGoneBeforeTheAgentRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostile = directory.appendingPathComponent("herdrm-agent-shims", isDirectory: true)
        try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hostile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostile.path) }

        let capture = directory.appendingPathComponent("binary")
        let executable = directory.appendingPathComponent("fake atomic")
        try "#!/bin/sh\nparent=$(/bin/ps -p \"$PPID\" -o command=)\nprintf '%s\\n' \"$parent\" > \"$CAPTURE_PARENT\"\nshim=${parent##* }\nif [ -e \"${shim%/pi}\" ]; then echo present; else echo absent; fi > \"$CAPTURE_SHIM_STATE\"\nprintf '%s\\n' \"$HERDRM_PI_COMPATIBLE_BINARY\" > \"$CAPTURE_DIR\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: executable.path, args: [])]
        let shimState = directory.appendingPathComponent("shim-state")
        let parent = directory.appendingPathComponent("parent")
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "CAPTURE_DIR": capture.path, "CAPTURE_SHIM_STATE": shimState.path, "CAPTURE_PARENT": parent.path,
        ]) { _, value in value }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), executable.path + "\n")
        let parentCommand = try String(contentsOf: parent, encoding: .utf8)
        XCTAssertTrue(parentCommand.contains("\(directory.path)/herdrm-agent-shims."), parentCommand)
        let second = Process()
        second.executableURL = process.executableURL
        second.arguments = process.arguments
        second.environment = process.environment
        try second.run()
        second.waitUntilExit()
        XCTAssertEqual(second.terminationStatus, 0)
        XCTAssertNotEqual(try String(contentsOf: parent, encoding: .utf8), parentCommand, "each launch needs a fresh shim path")
        XCTAssertEqual(try String(contentsOf: shimState, encoding: .utf8), "absent\n", "a killed pane must not leave the shim directory behind")
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("herdrm-agent-shims.") }, "private shim must be removed after exit")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: hostile.path).isEmpty)
    }

    func testHostileSharedSymlinkCannotRedirectShimAndOddBinaryNameKeepsArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let shared = directory.appendingPathComponent("herdrm-agent-shims")
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: target)
        let capture = directory.appendingPathComponent("args")
        let binary = directory.appendingPathComponent("atomic space\"$`name")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: binary.path, args: ["space value", "it's quoted"])]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "CAPTURE_ARGS": capture.path,
        ]) { _, value in value }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), "space value\nit's quoted\n")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("herdrm-agent-shims.") })
    }

    func testUnsetTMPDIRUsesPrivateDirectoryUnderSystemTmp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("parent")
        let binary = directory.appendingPathComponent("fake-atomic")
        try "#!/bin/sh\n/bin/ps -p \"$PPID\" -o command= > \"$CAPTURE_PARENT\"\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: binary.path, args: [])]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMPDIR")
        environment["CAPTURE_PARENT"] = capture.path
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let parent = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(parent.contains("/tmp/herdrm-agent-shims."), parent)
        let shim = parent.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").last!
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: shim).deletingLastPathComponent().path))
    }

    func testMissingBinaryExits127() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HerdrService.piCompatibleShellCommand(executable: "missing-atomic-binary", args: [])]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": directory.path,
            "TMPDIR": directory.path,
        ]) { _, value in value }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 127)
    }

    func testLivePiShimIsClassifiedAsPi() async throws {
        let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socketPath), "no local herdr server running")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parentFile = directory.appendingPathComponent("parent")
        func recordedShimDirectory() -> URL? {
            guard let parent = try? String(contentsOf: parentFile, encoding: .utf8),
                  let command = parent.split(whereSeparator: \.isWhitespace).last,
                  command.hasSuffix("/pi")
            else { return nil }
            let shim = URL(fileURLWithPath: String(command)).deletingLastPathComponent()
            guard shim.lastPathComponent.hasPrefix("herdrm-agent-shims."),
                  shim.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL
            else { return nil }
            return shim
        }
        defer {
            if let shim = recordedShimDirectory() { try? FileManager.default.removeItem(at: shim) }
            try? FileManager.default.removeItem(at: directory)
        }
        let sentinel = directory.appendingPathComponent("finished")
        let fake = directory.appendingPathComponent("fake-atomic")
        try "#!/bin/sh\nCAPTURE_PARENT='\(parentFile.path)'\nSENTINEL='\(sentinel.path)'\n/bin/ps -p \"$PPID\" -o command= > \"$CAPTURE_PARENT\"\ni=0; while [ ! -e \"$SENTINEL\" ] && [ \"$i\" -lt 100 ]; do sleep 0.1; i=$((i+1)); done\n[ -e \"$SENTINEL\" ]\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let service = HerdrService(device: .local, autoStartLocalServer: false)
        _ = try await service.connect()
        let paneID = try await service.createTab(workspaceID: nil, cwd: nil, label: "herdrm-test")
        var observed = "no snapshot"
        var recognized = false
        do {
            try await service.startPiCompatibleAgent(executable: fake.path, paneID: paneID, waitForShell: true)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            repeat {
                let snapshot = try await service.snapshot()
                observed = "agents=\(String(reflecting: snapshot.agents)); panes=\(String(reflecting: snapshot.panes))"
                recognized = snapshot.agents.contains { $0.paneID == paneID && $0.agent == "pi" }
                if recognized { break }
                try await Task.sleep(for: .milliseconds(250))
            } while clock.now < deadline
            let shim = try XCTUnwrap(recordedShimDirectory(), "fake did not record its shim parent")
            try Data().write(to: sentinel)
            let cleanupDeadline = clock.now.advanced(by: .seconds(5))
            while FileManager.default.fileExists(atPath: shim.path), clock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: shim.path), "shim should finish cleanup before pane closes")
        } catch {
            try? await service.closePane(paneID: paneID)
            throw error
        }
        try await service.closePane(paneID: paneID)
        XCTAssertTrue(recognized, "herdr did not classify fake as pi: \(observed)")
    }
}
#endif
