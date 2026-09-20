import Foundation
import Testing
@testable import Cleaner

@Suite struct LocalSnapshotsTests {
    @Test func parsesTmutilOutput() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-09-14-120000.local
        com.apple.TimeMachine.2026-09-15-083015.local
        com.apple.os.update-ABC
        """
        let snapshots = LocalSnapshots.parse(output)
        #expect(snapshots.map(\.identifier) == ["2026-09-15-083015", "2026-09-14-120000"])
        #expect(snapshots.allSatisfy { $0.date != nil })
        #expect(LocalSnapshots.parse("Snapshots for disk /:\n").isEmpty)
    }
}

@Suite struct VolumeVerifierTests {
    @Test func interpretsDiskutilOutput() {
        let ok = VolumeVerifier.interpret(status: 0, output: "Checking the fsroot tree\nThe volume /dev/rdisk3s1 appears to be OK\nFile system check exit code is 0\n")
        #expect(ok.ok)
        let bad = VolumeVerifier.interpret(status: 8, output: "Checking the fsroot tree\nerror: btn: invalid key order\nFile system check exit code is 8\n")
        #expect(!bad.ok)
        #expect(bad.summary.contains("invalid key order"))
    }
}

@Suite struct SpaceScannerTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test func sizesFoldersAndFindsLargestFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = 60_000_000
        try write(root.appendingPathComponent("Movies/holiday.mov"), bytes: big)
        try write(root.appendingPathComponent("Documents/notes.txt"), bytes: 1_000)
        try write(root.appendingPathComponent("Documents/Photos.photoslibrary/data/1.jpg"), bytes: big)
        try write(root.appendingPathComponent("Documents/Photos.photoslibrary/data/2.jpg"), bytes: big)
        try write(root.appendingPathComponent("loose.bin"), bytes: big)

        nonisolated(unsafe) var reports = 0
        let result = try SpaceScanner.scan(root: root) { _ in reports += 1 }
        #expect(result.folders.first?.name == "Documents")
        #expect(result.folders.map(\.name).contains("Movies"))
        #expect(result.totalBytes >= UInt64(4 * big))
        #expect(reports > 0)
        // 图库按整体算一个，里面的照片不单独出现
        let names = result.largestFiles.map(\.name)
        #expect(names.first == "Photos.photoslibrary")
        #expect(names.contains("holiday.mov") && names.contains("loose.bin"))
        #expect(!names.contains("1.jpg"))
        #expect(!names.contains("notes.txt"))
    }

    @Test func trashRulesStayInsideHomeAndAwayFromLibrary() {
        let home = URL(fileURLWithPath: "/Users/tester")
        #expect(SpaceScanner.canTrash(home.appendingPathComponent("Downloads/big.dmg"), home: home))
        #expect(SpaceScanner.canTrash(home.appendingPathComponent("Movies/a/b.mov"), home: home))
        #expect(!SpaceScanner.canTrash(home.appendingPathComponent("Library/Caches/x"), home: home))
        #expect(!SpaceScanner.canTrash(home.appendingPathComponent("Downloads"), home: home))
        #expect(!SpaceScanner.canTrash(home.appendingPathComponent(".docker/data.raw"), home: home))
        #expect(!SpaceScanner.canTrash(URL(fileURLWithPath: "/Applications/Xcode.app"), home: home))
        #expect(!SpaceScanner.canTrash(home.appendingPathComponent("Downloads/../../other/file"), home: home))
    }
}
