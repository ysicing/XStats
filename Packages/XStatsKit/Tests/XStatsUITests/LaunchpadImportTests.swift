// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SQLite3
import Testing
@testable import XStatsUI

struct LaunchpadImportTests {
  @Test func importsPagesAndFoldersFromWALWithoutChangingSystemDatabase() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(
      "LaunchpadImportTests-\(UUID())")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let source = directory.appendingPathComponent("db")
    var database: OpaquePointer?
    #expect(sqlite3_open(source.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      CREATE TABLE items (uuid TEXT,type INTEGER,parent_id INTEGER,ordering INTEGER);
      CREATE TABLE apps (item_id INTEGER,title TEXT,bundleid TEXT);
      CREATE TABLE groups (item_id INTEGER,title TEXT);
      PRAGMA wal_checkpoint(TRUNCATE);
      INSERT INTO items VALUES ('ROOTPAGE',1,0,0),('page1',3,1,0),
      ('app1',4,2,0),('folder',2,2,1),('folderPage',3,4,0),
      ('app2',4,5,0),('app3',4,5,1),('page2',3,1,1),('app4',4,8,0);
      INSERT INTO apps VALUES (3,'A','test.a'),(6,'B','test.b'),(7,'C','test.c'),(9,'D','test.d');
      INSERT INTO groups VALUES (4,'Tools');
      """
    #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
    let applications = try ["a", "b", "c", "d"].map { suffix in
      let bundle = directory.appendingPathComponent("\(suffix).app")
      let contents = bundle.appendingPathComponent("Contents")
      try manager.createDirectory(at: contents, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "test.\(suffix)", "CFBundleName": suffix],
        format: .xml, options: 0)
      try data.write(to: contents.appendingPathComponent("Info.plist"))
      return AppCommand(
        id: suffix, title: suffix, symbol: "app", keywords: "", action: .openApplication(bundle))
    }
    let original = try Data(contentsOf: source)
    let wal = URL(fileURLWithPath: source.path + "-wal")
    let originalWAL = try Data(contentsOf: wal)
    let imported = try LaunchpadImport.read(source, applications: applications)
    let layout = try #require(imported)
    #expect(layout.pages.count == 2)
    #expect(layout.pages[0][0] == .app("a"))
    #expect(layout.pages[0][1].name == "Tools")
    #expect(layout.pages[0][1].apps == ["b", "c"])
    #expect(layout.pages[1] == [.app("d")])
    #expect(try Data(contentsOf: source) == original)
    #expect(try Data(contentsOf: wal) == originalWAL)
  }

  @Test func unknownSchemaMissingDatabaseAndUntrustedPathsFailSafely() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(
      "LaunchpadInvalidTests-\(UUID())")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let source = directory.appendingPathComponent("db")
    #expect(try LaunchpadImport.read(source, applications: []) == nil)
    var database: OpaquePointer?
    #expect(sqlite3_open(source.path, &database) == SQLITE_OK)
    sqlite3_close(database)
    #expect(try LaunchpadImport.read(source, applications: []) == nil)
    let app = directory.appendingPathComponent("Fake.app")
    let receipt = app.appendingPathComponent("Contents/_MASReceipt")
    try manager.createDirectory(at: receipt, withIntermediateDirectories: true)
    try Data("fake".utf8).write(to: receipt.appendingPathComponent("receipt"))
    #expect(!LaunchpadApplicationRemoval.isCandidate(app))
    #expect(
      !LaunchpadApplicationRemoval.isCandidate(
        URL(fileURLWithPath: "/System/Applications/Safari.app")))
    #expect(throws: (any Error).self) { try LaunchpadApplicationRemoval.trash(app) }
    #expect(throws: (any Error).self) {
      try LaunchpadApplicationRemoval.validateAppStoreSignature(app)
    }
    #expect(manager.fileExists(atPath: app.path))
    let link = directory.appendingPathComponent("link")
    try manager.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(try LaunchpadImport.read(link, applications: []) == nil)
  }
}
