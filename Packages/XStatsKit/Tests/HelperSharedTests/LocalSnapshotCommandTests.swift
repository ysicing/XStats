import Testing
@testable import HelperShared

@Suite struct LocalSnapshotCommandTests {
    @Test func acceptsOnlyDateIdentifiers() {
        #expect(LocalSnapshotCommand.isValidIdentifier("2026-09-14-120000"))
        #expect(!LocalSnapshotCommand.isValidIdentifier("2026-09-14"))
        #expect(!LocalSnapshotCommand.isValidIdentifier("2026-09-14-120000; rm -rf /"))
        #expect(!LocalSnapshotCommand.isValidIdentifier("2026-09-14-12000a"))
        #expect(LocalSnapshotCommand.shellCommand(identifiers: ["2026-09-14-120000"]) == "/usr/bin/tmutil deletelocalsnapshots 2026-09-14-120000")
    }
}
