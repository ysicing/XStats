// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct AppUninstallerAuditTests {
  private struct Fixture {
    let home: URL

    init() throws {
      home = FileManager.default.temporaryDirectory
        .appendingPathComponent("uninstall-audit-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func app(_ name: String = "Product", identifier: String = "com.audit.product") throws
      -> InstalledApp
    {
      let url = home.appendingPathComponent("Applications/\(name).app")
      let info = url.appendingPathComponent("Contents/Info.plist")
      try FileManager.default.createDirectory(
        at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0
      ).write(to: info)
      return try #require(AppUninstaller.app(at: url))
    }

    func directory(_ relative: String) throws -> URL {
      let url = home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    func file(_ relative: String) throws -> URL {
      let url = home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("fixture".utf8).write(to: url)
      return url
    }

    func scan(_ app: InstalledApp, measureSizes: Bool = true) throws -> AppLeftoverScan {
      try AppUninstaller.scanLeftoversReport(
        for: app, home: home.path, identity: AppUninstallIdentity(app: app),
        installations: AppUninstaller.checkOtherInstallations(of: app, home: home.path),
        userCache: nil, measureSizes: measureSizes)
    }
  }

  @Test func independentDerivedApplicationKeepsItsOwnData() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    _ = try fixture.app("Product Pro", identifier: "com.audit.product.pro")
    let protected = [
      try fixture.directory("Library/Application Support/com.audit.product.pro"),
      try fixture.file("Library/Preferences/com.audit.product.pro.plist"),
      try fixture.directory("Library/Saved Application State/com.audit.product.pro.savedState"),
    ]

    let scan = try fixture.scan(app)

    #expect(scan.items.contains { $0.url.path == app.url.path })
    for url in protected {
      #expect(scan.items.contains { $0.url.path == url.path } == false)
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test func unknownDerivedIdentityRequiresReviewWhileOwnedFileSuffixesStaySelected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    let unknown = [
      try fixture.directory("Library/Application Support/com.audit.product.pro"),
      try fixture.file("Library/Preferences/com.audit.product.pro.plist"),
      try fixture.file("Library/LaunchAgents/com.audit.product.helper.plist"),
    ]
    let owned = [
      try fixture.file("Library/Preferences/com.audit.product.plist"),
      try fixture.directory("Library/Saved Application State/com.audit.product.savedState"),
    ]

    let scan = try fixture.scan(app)

    for url in unknown {
      #expect(scan.items.first { $0.url.path == url.path }?.requiresReview == true)
    }
    for url in owned {
      #expect(scan.items.first { $0.url.path == url.path }?.requiresReview == false)
    }
  }

  @Test func moreSpecificApplicationKeepsItsOwnDataWhenParentIdentifierIsInstalled() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    _ = try fixture.app()
    let app = try fixture.app("Product Pro", identifier: "com.audit.product.pro")
    let support = try fixture.directory("Library/Application Support/com.audit.product.pro")
    let preference = try fixture.file("Library/Preferences/com.audit.product.pro.plist")

    let scan = try fixture.scan(app)

    for url in [support, preference] {
      #expect(scan.items.first { $0.url.path == url.path }?.requiresReview == false)
    }
  }

  @Test func staleListedApplicationCannotScanAReplacement() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    _ = try fixture.directory("Library/Caches/com.audit.product")
    _ = try fixture.app(identifier: "com.audit.changed")

    #expect(throws: AppUninstallError.unsafePath(app.url.path)) {
      try fixture.scan(app)
    }
  }

  @Test(arguments: ["com.audit.different", "com.audit.product"], [false, true])
  func replacedApplicationInvalidatesApplicationAndResidualAuthorization(
    _ identifier: String, measureSizes: Bool
  )
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    let residual = try fixture.directory("Library/Caches/com.audit.product")
    let scan = try fixture.scan(app, measureSizes: measureSizes)
    try #require(scan.items.contains { $0.url.path == residual.path })
    try FileManager.default.moveItem(
      at: app.url, to: fixture.home.appendingPathComponent("Original.app"))
    _ = try fixture.app(identifier: identifier)

    for target in [app.url, residual] {
      #expect(throws: AppUninstallError.unsafePath(target.path)) {
        try AppUninstaller.validateLeftover(
          target, for: app, scan: scan, home: fixture.home.path, userCache: nil)
      }
    }
  }

  @Test func candidateDiscoveryKeepsOwnershipRulesBeforeMeasuringSizes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    _ = try fixture.app("Independent", identifier: "com.audit.product.independent")
    let cache = try fixture.directory("Library/Caches/com.audit.product")
    let shared = try fixture.directory("Library/Caches/com.audit.product.helper")
    _ = try fixture.directory("Library/Caches/com.audit.product.independent")
    _ = try fixture.file("Library/Caches/com.audit.product/data")

    let preview = try fixture.scan(app, measureSizes: false)
    let measured = try fixture.scan(app)
    #expect(preview.items.map(\.url) == measured.items.map(\.url))
    #expect(preview.items.map(\.requiresReview) == measured.items.map(\.requiresReview))
    #expect(preview.items.allSatisfy { !$0.isSizeKnown })
    #expect(measured.items.allSatisfy { $0.isSizeKnown })
    #expect(measured.items.first { $0.url.path == cache.path }?.size ?? 0 > 0)
    #expect(preview.items.first { $0.url.path == shared.path }?.requiresReview == true)
  }

  @Test func changedBundleIdentifierInSameDirectoryInvalidatesTheScan() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    let residual = try fixture.directory("Library/Caches/com.audit.product")
    let scan = try fixture.scan(app)
    _ = try fixture.app(identifier: "com.audit.changed")

    #expect(throws: AppUninstallError.unsafePath(residual.path)) {
      try AppUninstaller.validateLeftover(
        residual, for: app, scan: scan, home: fixture.home.path, userCache: nil)
    }
    #expect(throws: AppUninstallError.unsafePath(app.url.path)) {
      try AppUninstaller.validate(app, home: fixture.home.path)
    }
  }

  @Test func removedApplicationAllowsOnlyScannedResidualRetry() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let app = try fixture.app()
    let residual = try fixture.directory("Library/Caches/com.audit.product")
    let scan = try fixture.scan(app)
    try FileManager.default.moveItem(
      at: app.url, to: fixture.home.appendingPathComponent("Original.app"))

    #expect(throws: Never.self) {
      try AppUninstaller.validateLeftover(
        residual, for: app, scan: scan, home: fixture.home.path, userCache: nil)
    }
    #expect(throws: AppUninstallError.unsafePath(app.url.path)) {
      try AppUninstaller.validateLeftover(
        app.url, for: app, scan: scan, home: fixture.home.path, userCache: nil)
    }
  }
}
