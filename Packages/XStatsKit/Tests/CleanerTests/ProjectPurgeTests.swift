// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

private struct ProjectHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-project-purge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, age: TimeInterval = 30 * 86_400) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: url)
        let modified = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.deletingLastPathComponent().path)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("项目产物清理")
struct ProjectPurgeTests {
    @Test func defaultSearchDoesNotHardcodeWork() throws {
        let home = try ProjectHome()
        defer { home.remove() }
        let names = ["www", "dev", "Projects", "GitHub", "Code", "Workspace", "Repos",
                     "Development", "Library/CloudStorage", ".codex/worktrees", ".claude/worktrees"]
        for name in names + ["Work"] {
            try FileManager.default.createDirectory(at: home.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let roots = ProjectPurge.defaultSearchRoots(home: home.root.path)

        #expect(Set(roots.map { $0.lastPathComponent }) == Set(names.map { ($0 as NSString).lastPathComponent }))
    }

    @Test func configuredRootFindsProjectOutsideDefaultLocations() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Work/github/ysicing/demo/package.json")
        try home.file("Work/github/ysicing/demo/build/output.bin")
        let extra = home.root.appendingPathComponent("Work")

        let baseline = await ProjectPurge.scan(home: home.root.path)
        let configured = await ProjectPurge.scan(home: home.root.path, configuredRoots: [extra])

        #expect(baseline.items.isEmpty)
        #expect(configured.items.map(\.url.lastPathComponent) == ["build"])
    }

    @Test func overlappingConfiguredRootsDoNotDuplicateArtifacts() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/demo/package.json")
        try home.file("Projects/demo/build/output.bin")
        let extra = home.root.appendingPathComponent("Projects/demo")

        let scan = await ProjectPurge.scan(home: home.root.path,
                                          configuredRoots: [home.root.appendingPathComponent("Projects"), extra])

        #expect(scan.items.count == 1)
    }

    @Test func configuredRootsReplaceDefaultsIncludingAnEmptyList() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/default/package.json")
        try home.file("Projects/default/build/output.bin")
        try home.file("Work/github/ysicing/custom/package.json")
        try home.file("Work/github/ysicing/custom/build/output.bin")
        let custom = home.root.appendingPathComponent("Work")

        let disabled = await ProjectPurge.scan(home: home.root.path, configuredRoots: [])
        let configured = await ProjectPurge.scan(home: home.root.path, configuredRoots: [custom])

        #expect(disabled.items.isEmpty)
        #expect(configured.items.count == 1)
        #expect(configured.items.first?.project.lastPathComponent == "custom")
    }

    @Test func dependencyDirectoryIsNotDiscoveredAsAProjectRoot() throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("node_modules/package/package.json")
        try home.file("node_modules/package/dist/output.js")

        let roots = ProjectPurge.defaultSearchRoots(home: home.root.path)

        #expect(!roots.contains { $0.lastPathComponent == "node_modules" })
    }

    @Test func scanDoesNotDescendIntoUnownedDependencyDirectory() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/node_modules/package/package.json")
        try home.file("Projects/node_modules/package/dist/output.js")

        let scan = await ProjectPurge.scan(home: home.root.path)

        #expect(scan.items.isEmpty)
    }

    @Test func linkedDefaultRootIsReportedAsIncomplete() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("real-projects/app/package.json")
        let link = home.root.appendingPathComponent("Projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.root.appendingPathComponent("real-projects"))

        let scan = await ProjectPurge.scan(home: home.root.path)

        #expect(scan.failedRoots.contains { $0.lastPathComponent == "Projects" })
    }

    @Test func scanFindsArtifactsAndExcludesAuthoredContent() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/app/package.json")
        let dependency = try home.file("Projects/app/node_modules/package/index.js")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
                                              ofItemAtPath: dependency.deletingLastPathComponent().deletingLastPathComponent().path)
        let recent = try home.file("Projects/app/dist/output.js", age: 3600)
        try home.file("Projects/app/target/.git/config")
        try home.file("Projects/app/.build/deploy-keypair.json")
        try home.file("Projects/app/src/main.js")

        let scan = await ProjectPurge.scan(home: home.root.path)
        let paths = Set(scan.items.map(\.url.lastPathComponent))

        #expect(paths == ["node_modules", "dist"])
        // target 含 .git、.build 含部署密钥：计为受保护，而不是“无法确认”
        #expect(scan.protectedCount == 2)
        #expect(scan.unverifiedCount == 0)
        #expect(scan.items.first { $0.url.lastPathComponent == "node_modules" }?.isRecent == false)
        #expect(scan.items.first { $0.url.lastPathComponent == "dist" }?.isRecent == true)
        #expect(scan.items.contains { $0.url.path == dependency.path || $0.url.path == recent.path } == false)
    }

    @Test func trackedBuildDirectoryIsProtected() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        let project = home.root.appendingPathComponent("Projects/repo")
        try home.file("Projects/repo/package.json")
        try home.file("Projects/repo/build/tracked.txt")
        try runGit(["init", "-q"], at: project)
        try runGit(["add", "--", "build/tracked.txt"], at: project)

        let scan = await ProjectPurge.scan(home: home.root.path)

        #expect(!scan.items.contains { $0.url.lastPathComponent == "build" })
        #expect(scan.protectedCount == 1)
    }

    @Test func applicationBundlesAreNotDiscoveredOrScannedAsProjects() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Standalone.APP/package.json")
        try home.file("Standalone.APP/node_modules/runtime/index.js")
        try home.file("Downloads/demo/package.json")
        try home.file("Downloads/demo/build/output.bin")
        try home.file("Downloads/Example.app/Contents/Resources/app/package.json")
        try home.file("Downloads/Example.app/Contents/Resources/app/node_modules/runtime/index.js")

        let roots = ProjectPurge.defaultSearchRoots(home: home.root.path)
        #expect(!roots.contains { $0.lastPathComponent == "Standalone.APP" })
        let scan = await ProjectPurge.scan(home: home.root.path)
        #expect(scan.items.map { $0.project.lastPathComponent } == ["demo"])
    }

    @Test func applicationBundleRootsAndTheirContentsAreRejected() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Downloads/Example.APP/Contents/Resources/app/package.json")
        try home.file("Downloads/Example.APP/Contents/Resources/app/dist/runtime.js")
        let bundle = home.root.appendingPathComponent("Downloads/Example.APP")
        let contents = bundle.appendingPathComponent("Contents/Resources/app")
        let alias = home.root.appendingPathComponent("linked-runtime")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: contents)

        for root in [bundle, contents, alias] {
            #expect(ProjectPurge.validatedAdditionalRoot(root, home: home.root.path) == nil)
        }
        let scan = await ProjectPurge.scan(home: home.root.path, configuredRoots: [bundle, contents])
        #expect(scan.items.isEmpty)
    }

    @Test func contentStagedDuringBatchCleanupIsProtected() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        let repo = home.root.appendingPathComponent("Projects/repo")
        for name in ["a", "b"] {
            try home.file("Projects/repo/\(name)/package.json")
            try home.file("Projects/repo/\(name)/build/output.bin")
        }
        try runGit(["init", "-q"], at: repo)
        let scan = await ProjectPurge.scan(home: home.root.path, configuredRoots: [repo])
        #expect(scan.items.map { $0.project.lastPathComponent } == ["a", "b"])
        let first = try #require(scan.items.first)

        let report = await ProjectPurge.clean(scan, selected: Set(scan.items.map(\.id)), trash: { url in
            if url == first.url {
                // 模拟处理第一项期间用户暂存第二项；git add 不改变产物的 inode 或内容修改时间。
                try runGit(["add", "-f", "--", "b/build/output.bin"], at: repo)
            } else {
                Issue.record("清理期间已被 Git 跟踪的文件不能移到废纸篓")
            }
        })

        #expect(report.trashedIDs == [first.id])
        #expect(report.skippedCount == 1)
    }

    @Test func oneGitQueryPerRepositoryStillSeparatesTrackedArtifacts() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        let repo = home.root.appendingPathComponent("Projects/mono")
        try home.file("Projects/mono/package.json")
        for name in ["a", "b", "c"] {
            try home.file("Projects/mono/packages/\(name)/package.json")
            try home.file("Projects/mono/packages/\(name)/dist/index.js")
        }
        // 只有 b 的产物被 Git 跟踪；前缀相同的 dist-extra 被跟踪不应波及 dist
        try home.file("Projects/mono/packages/a/dist-extra/keep.txt")
        try runGit(["init", "-q"], at: repo)
        // -f：开发者全局 gitignore 常忽略 dist，测试不能依赖本机配置
        try runGit(["add", "-f", "--", "packages/b/dist/index.js", "packages/a/dist-extra/keep.txt"], at: repo)

        let scan = await ProjectPurge.scan(home: home.root.path)
        let dists = Set(scan.items.filter { $0.url.lastPathComponent == "dist" }.map { $0.project.lastPathComponent })

        #expect(dists == ["a", "c"])
        #expect(scan.protectedCount == 1)
    }

    @Test func missingDeveloperToolsKeepsRepositoryArtifactsWithoutRunningGit() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/repo/package.json")
        try home.file("Projects/repo/.git/HEAD")
        try home.file("Projects/repo/build/output.bin")
        try home.file("Projects/plain/package.json")
        try home.file("Projects/plain/build/output.bin")

        let scan = await ProjectPurge.scan(home: home.root.path, now: Date(), configuredRoots: nil, developerTools: false)

        // 不在仓库里的产物无需 git，照常列出；仓库里的全部保留并说明原因
        #expect(scan.items.map { $0.project.lastPathComponent } == ["plain"])
        #expect(scan.unverifiedCount == 1)
        #expect(scan.developerToolsMissing)

        let plain = try #require(scan.items.first)
        let report = await ProjectPurge.clean(scan, selected: [plain.id], trash: { _ in }, developerTools: false)
        #expect(report.trashedIDs == [plain.id])
    }

    @Test func developerToolsProbeTreatsXcodeSelectFailureAsMissing() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-xcode-select-\(UUID())")
        defer { try? FileManager.default.removeItem(at: script) }
        // 未安装开发者工具时 xcode-select -p 以非零状态退出，不弹窗
        try "#!/bin/sh\necho 'xcode-select: error: unable to get active developer directory' >&2\nexit 2\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(!ProjectPurge.developerToolsInstalled(xcodeSelect: script.path))

        let wrongPath = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-xcode-select-\(UUID())")
        defer { try? FileManager.default.removeItem(at: wrongPath) }
        try "#!/bin/sh\necho /nonexistent/Developer\n".write(to: wrongPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrongPath.path)
        #expect(!ProjectPurge.developerToolsInstalled(xcodeSelect: wrongPath.path))
    }

    @Test func libraryAndHiddenFoldersAreNotAcceptedAsSearchRoots() throws {
        let home = try ProjectHome()
        defer { home.remove() }
        func folder(_ path: String) throws -> URL {
            let url = home.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // 应用数据和编辑器扩展里有 package.json，其中的 dist/ 被清掉会损坏它们
        for rejected in ["Library/Application Support/Code", "Library/Developer/Xcode", ".vscode/extensions",
                         ".codex/sessions", "Projects/.cache", "Library/CloudStorage/Drive/.hidden"] {
            #expect(ProjectPurge.validatedAdditionalRoot(try folder(rejected), home: home.root.path) == nil, "\(rejected)")
        }
        for accepted in ["Library/CloudStorage/Drive", "Library/Mobile Documents/com~apple~CloudDocs",
                         ".codex/worktrees/repo", ".claude/worktrees", "Work/github"] {
            #expect(ProjectPurge.validatedAdditionalRoot(try folder(accepted), home: home.root.path) != nil, "\(accepted)")
        }
    }

    @Test func savedLibraryRootIsNotScanned() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file(".vscode/extensions/ext/package.json")
        try home.file(".vscode/extensions/ext/dist/extension.js")
        let saved = home.root.appendingPathComponent(".vscode/extensions")

        let scan = await ProjectPurge.scan(home: home.root.path, configuredRoots: [saved])

        #expect(scan.items.isEmpty)
    }

    @Test func largestProjectsComeFirstAndCleanReportsTrashedIDs() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/a-small/package.json")
        try home.file("Projects/a-small/build/one.bin")
        try home.file("Projects/z-large/package.json")
        for index in 0..<4 { try home.file("Projects/z-large/build/\(index).bin") }
        try home.file("Projects/z-large/dist/one.bin")

        let scan = await ProjectPurge.scan(home: home.root.path)

        #expect(scan.items.map { "\($0.project.lastPathComponent)/\($0.url.lastPathComponent)" }
                == ["z-large/build", "z-large/dist", "a-small/build"])
        let target = try #require(scan.items.first)
        let report = await ProjectPurge.clean(scan, selected: [target.id], trash: { _ in })
        #expect(report.trashedIDs == [target.id])
        #expect(scan.removing(report.trashedIDs).items.map(\.id) == scan.items.dropFirst().map(\.id))
    }

    @Test func scanIncludesCloudAndAgentWorktrees() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Library/CloudStorage/provider/app/package.json")
        try home.file("Library/CloudStorage/provider/app/build/output.bin")
        try home.file(".codex/worktrees/repo/Cargo.toml")
        try home.file(".codex/worktrees/repo/target/output.bin")

        let scan = await ProjectPurge.scan(home: home.root.path)

        #expect(scan.items.contains { $0.url.lastPathComponent == "build" && $0.isCloud })
        #expect(scan.items.contains { $0.url.lastPathComponent == "target" && $0.isWorktree })
    }

    @Test func customICloudDriveRootIsMarkedAsCloud() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Library/Mobile Documents/provider/app/package.json")
        try home.file("Library/Mobile Documents/provider/app/build/output.bin")
        let iCloud = home.root.appendingPathComponent("Library/Mobile Documents")

        let scan = await ProjectPurge.scan(home: home.root.path, configuredRoots: [iCloud])

        #expect(scan.items.first { $0.url.lastPathComponent == "build" }?.isCloud == true)
    }

    @Test func selectedArtifactMovesToTrash() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/app/package.json")
        let original = try home.file("Projects/app/build/output.bin")
        let scan = await ProjectPurge.scan(home: home.root.path)
        let item = try #require(scan.items.first { $0.url.lastPathComponent == "build" })
        let destination = home.root.appendingPathComponent("test-trash")

        let report = await ProjectPurge.clean(scan, selected: [item.id], trash: { url in
            try FileManager.default.moveItem(at: url, to: destination)
        })

        #expect(report.trashedCount == 1)
        #expect(report.trashedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("output.bin").path))
    }

    @Test func changedDirectoryCannotBeTrashedFromOldScan() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/app/package.json")
        let original = try home.file("Projects/app/build/old.bin")
        let scan = await ProjectPurge.scan(home: home.root.path)
        let item = try #require(scan.items.first { $0.url.lastPathComponent == "build" })
        let oldDirectory = original.deletingLastPathComponent()
        try FileManager.default.moveItem(at: oldDirectory, to: oldDirectory.deletingLastPathComponent().appendingPathComponent("previous-build"))
        let replacement = try home.file("Projects/app/build/new.bin")

        let report = await ProjectPurge.clean(scan, selected: [item.id], trash: { _ in
            Issue.record("被替换的目录不应进入废纸篓")
        })

        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test func changedScanRootCannotBeTrashed() async throws {
        let home = try ProjectHome()
        defer { home.remove() }
        try home.file("Projects/app/package.json")
        try home.file("Projects/app/build/old.bin")
        let scan = await ProjectPurge.scan(home: home.root.path)
        let item = try #require(scan.items.first { $0.url.lastPathComponent == "build" })
        let root = home.root.appendingPathComponent("Projects")
        try FileManager.default.moveItem(at: root, to: home.root.appendingPathComponent("old-projects"))
        let replacement = try home.file("Projects/app/build/new.bin")

        let report = await ProjectPurge.clean(scan, selected: [item.id], trash: { _ in
            Issue.record("被替换的扫描根目录不应进入废纸篓")
        })

        #expect(report.trashedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: replacement.path))
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
