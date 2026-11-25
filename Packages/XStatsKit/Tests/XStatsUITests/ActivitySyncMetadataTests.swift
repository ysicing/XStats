// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import os
import Testing
import WebDAVSync
@testable import XStatsUI

struct ActivitySyncMetadataTests {
  private let key = SymmetricKey(size: .bits256)
  private let directory = [ActivitySyncRemotePath.metadata]
  private let marker = [ActivitySyncRemotePath.marker]

  enum FolderRoot: String, CaseIterable, Sendable {
    case parent, selectedXStats
  }

  @Test(arguments: FolderRoot.allCases)
  func folderUsesOneDatasetRoot(_ scenario: FolderRoot) async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let canonical = base.appendingPathComponent("XStats", isDirectory: true)
    if scenario == .selectedXStats {
      try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false)
    }
    let device = UUID()
    let folder = ActivitySyncFolder(root: scenario == .selectedXStats ? canonical : base)
    let engine = ActivitySyncEngine(key: key)
    #expect(await engine.datasetIdentifier == nil)
    try await engine.exchangeMetadata(device: device, repository: folder) { snapshot in
      #expect(snapshot.isEmpty)
      return Data("metadata".utf8)
    }
    let remoteMarker = try await folder.read(marker)
    let authenticatedMarker = try #require(remoteMarker)
    #expect(
      await engine.datasetIdentifier
        == (try ActivitySyncCipher(key: key).authenticateMarker(authenticatedMarker)))
    let path = try ActivitySyncCipher(key: key).metadataPath(for: device)
    let file = path.reduce(canonical) { $0.appendingPathComponent($1) }
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(
      !FileManager.default.fileExists(atPath: canonical.appendingPathComponent("XStats").path))
  }

  @Test func exchangesAuthenticatedSnapshotsAndOnlyOverwritesTheCallingDevice() async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = ActivitySyncFolder(root: base)
    let first = UUID()
    let second = UUID()
    let firstEngine = ActivitySyncEngine(key: key)
    let secondEngine = ActivitySyncEngine(key: key)
    let firstData = Data("first computer metadata".utf8)
    let secondData = Data("second computer metadata".utf8)
    let revised = Data("updated first computer metadata".utf8)
    let cipher = ActivitySyncCipher(key: key)
    let firstPath = try cipher.metadataPath(for: first)
    let secondPath = try cipher.metadataPath(for: second)

    try await firstEngine.exchangeMetadata(device: first, repository: repository) { _ in firstData }
    try await secondEngine.exchangeMetadata(device: second, repository: repository) { snapshot in
      #expect(snapshot == [first: firstData])
      return secondData
    }
    let original = try await repository.read(firstPath)
    let secondCiphertext = try await repository.read(secondPath)
    let verified = try await firstEngine.exchangeMetadata(device: first, repository: repository) {
      snapshot in
      #expect(snapshot == [first: firstData, second: secondData])
      return revised
    }
    #expect(verified == [first: revised, second: secondData])
    let names = try await repository.list(directory)
    let ciphertext = try await repository.read(firstPath)
    let stored = try #require(ciphertext)
    #expect(names.count == 2)
    #expect(stored != original)
    #expect(stored.range(of: revised) == nil)
    #expect(try await repository.read(secondPath) == secondCiphertext)
    let skipped = try await secondEngine.exchangeMetadata(device: second, repository: repository) {
      snapshot in
      #expect(snapshot == [first: revised, second: secondData])
      return nil
    }
    #expect(skipped == nil)
    #expect(try await repository.read(firstPath) == ciphertext)
    #expect(try await repository.read(secondPath) == secondCiphertext)
    try await firstEngine.run(store: ActivityStore(url: nil), device: first, repository: repository)
  }

  @Test func unchangedMetadataVersionsAreNotDownloadedAgain() async throws {
    let repository = VersionedMetadataRepository()
    let first = UUID()
    let second = UUID()
    let firstEngine = ActivitySyncEngine(key: key)
    let secondEngine = ActivitySyncEngine(key: key)
    let firstData = Data("first computer metadata".utf8)
    let secondData = Data("second computer metadata".utf8)
    let revised = Data("revised second computer metadata".utf8)
    try await secondEngine.exchangeMetadata(device: second, repository: repository) { _ in
      secondData
    }
    try await firstEngine.exchangeMetadata(device: first, repository: repository) { _ in
      firstData
    }

    await repository.resetMetadataReads()
    let skipped = try await firstEngine.exchangeMetadata(device: first, repository: repository) {
      snapshot in
      #expect(snapshot == [first: firstData, second: secondData])
      return nil
    }
    #expect(skipped == nil)
    #expect(await repository.metadataReads == 0)

    try await secondEngine.exchangeMetadata(device: second, repository: repository) { _ in
      revised
    }
    await repository.resetMetadataReads()
    try await firstEngine.exchangeMetadata(device: first, repository: repository) { snapshot in
      #expect(snapshot == [first: firstData, second: revised])
      return nil
    }
    #expect(await repository.metadataReads == 1)
  }

  @Test func rejectsMissingOrForeignMarkerAndMetadataMovedToAnotherDevice() async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = ActivitySyncFolder(root: base)
    let device = UUID()
    let cipher = ActivitySyncCipher(key: key)
    let path = try cipher.metadataPath(for: device)
    let other = try cipher.metadataPath(for: UUID())
    let data = try cipher.sealMetadata(Data([12]), at: path)
    try await repository.replaceMetadata(data, at: path)
    let engine = ActivitySyncEngine(key: key)
    let unexpectedTransform: @Sendable ([UUID: Data]) async throws -> Data? = { _ in
      Issue.record("Unauthenticated metadata must never reach the transform")
      return nil
    }
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await engine.exchangeMetadata(
        device: device, repository: repository, transform: unexpectedTransform)
    }
    #expect(try await repository.read(marker) == nil)

    #expect(try await repository.create(cipher.makeMarker(), at: marker))
    let foreign = ActivitySyncEngine(key: SymmetricKey(size: .bits256))
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await foreign.exchangeMetadata(
        device: device, repository: repository, transform: unexpectedTransform)
    }
    try await repository.replaceMetadata(data, at: other)
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await engine.exchangeMetadata(
        device: device, repository: repository, transform: unexpectedTransform)
    }
    #expect(try await repository.read(path) == data)
  }

  @Test func boundsMetadataAndRefusesToReplaceTheMarkerOrFollowSymlinks() async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = ActivitySyncFolder(root: base)
    let engine = ActivitySyncEngine(key: key)
    let device = UUID()
    let path = try ActivitySyncCipher(key: key).metadataPath(for: device)
    let oversized = Data(count: ActivitySyncRemotePath.maximumMetadataBytes + 1)
    await #expect(throws: ActivitySyncFailure.limit) {
      try await engine.exchangeMetadata(device: device, repository: repository) { _ in oversized }
    }
    #expect(try await repository.list(directory).isEmpty)
    await #expect(throws: ActivitySyncFailure.invalidListing) {
      try await repository.replaceMetadata(Data(), at: marker)
    }
    let root = base.appendingPathComponent("XStats")
    let file = path.reduce(root) { $0.appendingPathComponent($1) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
    try oversized.write(to: file)
    await #expect(throws: ActivitySyncFailure.limit) { try await repository.read(path) }
    try FileManager.default.removeItem(at: file)
    let dataset = root.appendingPathComponent("dataset")
    let original = try Data(contentsOf: dataset)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dataset)
    await #expect(throws: ActivitySyncFailure.invalidListing) {
      try await repository.replaceMetadata(Data(), at: path)
    }
    #expect(try Data(contentsOf: dataset) == original)
  }

  @Test(arguments: [false, true])
  func rejectsOverlappingWorkAndReauthenticatesAfterTransform(_ replaceMarker: Bool) async throws {
    let base = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let repository = ActivitySyncFolder(root: base)
    let engine = ActivitySyncEngine(key: key)
    let device = UUID()
    let dataset = base.appendingPathComponent("XStats").appendingPathComponent("dataset")
    let differentMarker = try ActivitySyncCipher(key: key).makeMarker()
    let transform: @Sendable ([UUID: Data]) async throws -> Data? = { _ in
      await #expect(throws: ActivitySyncFailure.busy) {
        try await engine.exchangeMetadata(device: device, repository: repository) { _ in nil }
      }
      if replaceMarker {
        try differentMarker.write(to: dataset, options: .atomic)
      } else {
        try FileManager.default.removeItem(at: dataset)
      }
      return Data([42])
    }
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await engine.exchangeMetadata(
        device: device, repository: repository, transform: transform)
    }
    #expect(try await repository.list(directory).isEmpty)
  }

  @Test(arguments: [false, true])
  func writeAcknowledgmentRequiresTheNewLocalBytesAndAnAuthenticatedPeer(_ corruptPeer: Bool)
    async throws
  {
    let device = UUID()
    let cipher = ActivitySyncCipher(key: key)
    let own = try cipher.metadataPath(for: device)
    let peer = try cipher.metadataPath(for: UUID())
    let previous = Data([1])
    let prepared = Data([2])
    let repository = MetadataReadbackFixture(
      files: [
        marker: try cipher.makeMarker(),
        own: try cipher.sealMetadata(previous, at: own),
        peer: try cipher.sealMetadata(Data([3]), at: peer),
      ],
      corruptPeer: corruptPeer ? peer : nil)
    await #expect(throws: ActivitySyncFailure.authenticationFailed) {
      try await ActivitySyncEngine(key: key).exchangeMetadata(
        device: device, repository: repository
      ) { snapshot in
        #expect(snapshot.count == 2)
        #expect(snapshot[device] == previous)
        return prepared
      }
    }
    #expect(await repository.replaced == [own])
  }

  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ActivitySyncMetadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

/// 模拟带强 ETag 的远端：每次写入都会产生新版本。
private actor VersionedMetadataRepository: ActivitySyncRepository {
  private var files: [[String]: (data: Data, version: Int)] = [:]
  private var nextVersion = 0
  private(set) var metadataReads = 0

  func resetMetadataReads() { metadataReads = 0 }

  func list(_ directory: [String]) -> Set<String> {
    listActivityObjects(directory).names
  }

  func listActivityObjects(_ directory: [String]) -> ActivitySyncListing {
    var listing = ActivitySyncListing()
    for (path, file) in files where path.count > directory.count && path.starts(with: directory) {
      let name = path[directory.count]
      listing.names.insert(name)
      if path.count == directory.count + 1 { listing.versions[name] = "\"\(file.version)\"" }
    }
    return listing
  }

  func read(_ path: [String]) -> Data? {
    if ActivitySyncRemotePath.validMetadataObject(path) { metadataReads += 1 }
    return files[path]?.data
  }

  func create(_ data: Data, at path: [String]) -> Bool {
    guard files[path] == nil else { return false }
    store(data, at: path)
    return true
  }

  func replaceMetadata(_ data: Data, at path: [String]) {
    store(data, at: path)
  }

  private func store(_ data: Data, at path: [String]) {
    nextVersion += 1
    files[path] = (data, nextVersion)
  }
}

private actor MetadataReadbackFixture: ActivitySyncRepository {
  private var files: [[String]: Data]
  private let corruptPeer: [String]?
  private(set) var replaced: [[String]] = []

  init(files: [[String]: Data], corruptPeer: [String]?) {
    self.files = files
    self.corruptPeer = corruptPeer
  }

  func list(_ directory: [String]) -> Set<String> {
    Set(
      files.keys.compactMap {
        $0.count > directory.count && $0.starts(with: directory) ? $0[directory.count] : nil
      })
  }

  func read(_ path: [String]) -> Data? { files[path] }

  func create(_ data: Data, at path: [String]) -> Bool {
    Issue.record("The existing dataset marker must not be recreated")
    return false
  }

  func replaceMetadata(_ data: Data, at path: [String]) {
    replaced.append(path)
    guard let corruptPeer else { return }
    files[path] = data
    files[corruptPeer] = Data([0])
  }
}

private final class MetadataDAVProtocol: URLProtocol, @unchecked Sendable {
  typealias Response = @Sendable (URLRequest) -> WebDAVResponse
  static let responses = OSAllocatedUnfairLock(initialState: [String: Response]())

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host,
      let respond = Self.responses.withLock({ $0[host] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let response = respond(request)
    guard
      let http = HTTPURLResponse(
        url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(response.data.count)])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    if !response.data.isEmpty { client?.urlProtocol(self, didLoad: response.data) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

struct ActivitySyncMetadataWebDAVTests {
  enum ConfiguredRoot: String, CaseIterable, Sendable {
    case parent, selectedXStats
  }

  @Test(arguments: ConfiguredRoot.allCases)
  func httpsMetadataPutReplacesAtXStatsRoot(_ configured: ConfiguredRoot) async throws {
    let host = "sync-\(UUID().uuidString.lowercased()).test"
    let root = "/share/XStats/"
    let base = configured == .parent ? "/share/" : root
    let collection = root + "metadata/"
    let cipher = ActivitySyncCipher(key: SymmetricKey(size: .bits256))
    let path = try cipher.metadataPath(for: UUID())
    let file = root + path.joined(separator: "/")
    let original = try cipher.sealMetadata(Data([1]), at: path)
    let replacement = try cipher.sealMetadata(Data([2]), at: path)
    let oversized = Data(count: ActivitySyncRemotePath.maximumMetadataBytes + 1)
    var expected = [("PUT", file, 409)]
    if configured == .parent { expected.append(("MKCOL", root, 201)) }
    expected += [
      ("MKCOL", collection, 201), ("PUT", file, 201),
      ("GET", file, 200), ("PUT", file, 204), ("GET", file, 200), ("GET", file, 200),
    ]
    let requests = OSAllocatedUnfairLock(initialState: 0)
    let responses = [original, replacement, oversized]
    let gets = OSAllocatedUnfairLock(initialState: 0)
    let respond: MetadataDAVProtocol.Response = { [expected] request in
      let index = requests.withLock {
        let index = $0
        $0 += 1
        return index
      }
      guard expected.indices.contains(index), let url = request.url else {
        Issue.record("Unexpected WebDAV request")
        return WebDAVResponse(data: Data(), status: 500)
      }
      let (method, requestPath, status) = expected[index]
      #expect(request.httpMethod == method)
      #expect(URLComponents(url: url, resolvingAgainstBaseURL: true)?.path == requestPath)
      if method == "PUT" {
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
      }
      let data: Data
      if method == "GET" {
        data = gets.withLock {
          let data = responses[$0]
          $0 += 1
          return data
        }
      } else {
        data = Data()
      }
      return WebDAVResponse(data: data, status: status)
    }
    MetadataDAVProtocol.responses.withLock { $0[host] = respond }
    defer { _ = MetadataDAVProtocol.responses.withLock { $0.removeValue(forKey: host) } }
    let configuration = try ActivityDAVConfiguration(
      address: "https://\(host)\(base)", username: "fixture-user")
    let repository = ActivitySyncWebDAV(configuration: configuration, password: "fixture-secret") {
      let options = URLSessionConfiguration.ephemeral
      options.protocolClasses = [MetadataDAVProtocol.self]
      return options
    }
    try await repository.replaceMetadata(original, at: path)
    #expect(try await repository.read(path) == original)
    try await repository.replaceMetadata(replacement, at: path)
    #expect(try await repository.read(path) == replacement)
    await #expect(throws: ActivitySyncFailure.limit) { try await repository.read(path) }
    #expect(requests.withLock { $0 } == expected.count)
  }

  @Test func privateHTTPRejectsUnconditionalDatasetPutAndUnrecognizedMetadataConditions()
    async throws
  {
    let configuration = try ActivityDAVConfiguration(
      address: "http://nas.local/share/", username: "fixture-user")
    let transport = ActivityDAVHTTPTransport(
      resolve: { _ in
        Issue.record("Invalid PUT should be rejected before resolving the host")
        return []
      },
      discoverTunnels: { [] },
      exchange: { _, _, _ in
        Issue.record("Invalid PUT should never reach the wire")
        throw WebDAVError.transport
      })
    let object = "metadata/" + String(repeating: "a", count: 64)
    for (path, header, value) in [
      ("dataset", "If-None-Match", nil),
      (object, "If-None-Match", "\"other\""),
      (object, "If-Match", "*"),
    ] {
      var request = URLRequest(url: configuration.directoryURL.appendingPathComponent(path))
      request.httpMethod = "PUT"
      request.httpBody = Data(repeating: 0x61, count: 32)
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue(value, forHTTPHeaderField: header)
      await #expect(throws: WebDAVError.transport) {
        try await transport.send(request, endpoint: configuration.endpoint, limit: 1024)
      }
    }
  }
}
