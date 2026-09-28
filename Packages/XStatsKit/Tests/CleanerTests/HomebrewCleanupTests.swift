// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

@Suite struct HomebrewCleanupTests {
    @Test func previewIncludesPrunedContainersAndUsesNativeTotal() throws {
        let preview = try HomebrewCleanup.parsePreview("""
        Warning: Skipping tool: most recent version is not installed
        Would remove: /custom prefix/Cellar/tool (extra)/1.0 (1,234 files, 1.2MB)
        Would prune 3 files from: /custom cache/downloads
        Would remove (broken link): /custom prefix/bin/old-tool
        Would remove (empty directory): /custom prefix/empty
        ==> This operation would free approximately 2.3MB of disk space.
        """)
        #expect(preview.items.map(\.url.path) == ["/custom prefix/Cellar/tool (extra)/1.0", "/custom cache/downloads",
                                                "/custom prefix/bin/old-tool", "/custom prefix/empty"])
        #expect(preview.totalSize == 2_300_000)
        #expect(!preview.details.contains("Skipping"))
    }

    @Test func emptyPreviewAndZeroByteActionsAreDifferent() throws {
        #expect(try HomebrewCleanup.parsePreview("Warning: Skipping tool").items.isEmpty)
        let preview = try HomebrewCleanup.parsePreview("Would remove (empty directory): /opt/homebrew/empty")
        #expect(preview.items.count == 1)
        #expect(preview.totalSize == 0)
    }

    @Test(arguments: ["Would remove: /tmp/cache (unknown)", "Would remove: relative (1MB)",
                      "Would prune 3 files from: /tmp/cache", "Would delete: /tmp/cache",
                      "==> This operation would free approximately 1MB of disk space."])
    func unknownPlanDoesNotBecomeAnEmptySuccessfulPreview(_ output: String) {
        #expect(throws: HomebrewCleanup.PreviewError.self) { try HomebrewCleanup.parsePreview(output) }
    }

    @Test func previewFailureBlocksCleaningAndDoesNotRequestDiskAccess() async {
        let environment = CleanEnvironment(runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
                                           runTool: { _, _ in ToolRunResult(status: 7, output: "permission denied by brew") })
        let scan = await CleanEngine.scan([RuleCatalog.homebrewCache], environment: environment)
        #expect(scan.first?.isCleanable == false)
        guard case .previewFailed(let message) = scan.first?.blocked else {
            Issue.record("brew 预览失败必须明确报告"); return
        }
        #expect(message.contains("permission denied by brew"))
    }

    @Test func cleanupFailureKeepsNativeError() async throws {
        let environment = CleanEnvironment(runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
            runTool: { _, arguments in
                if arguments.contains("--dry-run") {
                    return ToolRunResult(status: 0, output: "Would remove: /opt/homebrew/Cellar/tool/1 (1MB)")
                }
                throw ToolExecutionError.failed(tool: "brew", status: 1, output: "cannot acquire lock")
            })
        let scans = await CleanEngine.scan([RuleCatalog.homebrewCache], environment: environment)
        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.homebrewCache.id], preferTrash: false,
                                             environment: environment, log: nil)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("cannot acquire lock") == true)
        #expect(report.freedBytes == 0)
    }

    @Test func cancelledCleanupIsNotReportedAsAToolFailure() async {
        let environment = CleanEnvironment(runningBundleIdentifiers: { [] }, isToolAvailable: { _ in true },
            runTool: { _, arguments in
                if arguments.contains("--dry-run") {
                    return ToolRunResult(status: 0, output: "Would remove: /opt/homebrew/Cellar/tool/1 (1MB)")
                }
                throw CancellationError()
            })
        let scans = await CleanEngine.scan([RuleCatalog.homebrewCache], environment: environment)
        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.homebrewCache.id], preferTrash: false,
                                             environment: environment, log: nil)
        #expect(report.failures.isEmpty)
        #expect(report.wasCancelled)
        #expect(report.removedCount == 0)
    }

    @Test func brewRunnerSetsSafetyEnvironmentAndKeepsArguments() async throws {
        let home = try stubBrew("""
        #!/bin/sh
        printf '%s\\n' "$HOMEBREW_NO_AUTO_UPDATE|$HOMEBREW_NO_AUTOREMOVE|$HOMEBREW_NO_ANALYTICS|$HOMEBREW_NO_COLOR|$NONINTERACTIVE|$LC_ALL"
        printf '%s\\n' "$@"
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try await DeveloperToolRunner.run("brew", arguments: ["cleanup", "--prune=30", "--dry-run"], home: home.path)
        #expect(result.output == "1|1|1|1|1|en_US.UTF-8\ncleanup\n--prune=30\n--dry-run")
    }

    @Test func brewRunnerTimesOutAndBoundsOutput() async throws {
        let home = try stubBrew("#!/bin/sh\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            _ = try await DeveloperToolRunner.run("brew", arguments: [], home: home.path, timeout: 0.1)
            Issue.record("超时命令不应成功")
        } catch ToolExecutionError.timedOut { }
        try "#!/bin/sh\nprintf '1234567890'\n".write(to: home.appendingPathComponent(".local/bin/brew"), atomically: false, encoding: .utf8)
        do {
            _ = try await DeveloperToolRunner.run("brew", arguments: [], home: home.path, outputLimit: 8)
            Issue.record("超出限制的输出不应成功")
        } catch ToolExecutionError.outputTooLarge { }
    }

    @Test func brewRunnerCancellationStopsTheStartedProcess() async throws {
        let home = try stubBrew("#!/bin/sh\necho $$ > \"$HOME/pid\"\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let task = Task { try await DeveloperToolRunner.run("brew", arguments: [], home: home.path) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let pidFile = home.appendingPathComponent("pid")
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消命令不应成功")
        } catch is CancellationError { }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        #expect(kill(pid, 0) != 0)
    }

    private func stubBrew(_ script: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-brew-test-\(UUID())")
        let executable = home.appendingPathComponent(".local/bin/brew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return home
    }
}
