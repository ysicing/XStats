// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import WebDAVSync

actor ActivitySyncWebDAV: ActivitySyncRepository {
  let configuration: ActivityDAVConfiguration
  private let password: String
  private let httpTransport: ActivityDAVHTTPTransport
  private let makeSessionConfiguration: @Sendable () -> URLSessionConfiguration

  init(
    configuration: ActivityDAVConfiguration, password: String,
    httpTransport: ActivityDAVHTTPTransport = ActivityDAVHTTPTransport(),
    makeSessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
  ) {
    self.configuration = configuration
    self.password = password
    self.httpTransport = httpTransport
    self.makeSessionConfiguration = makeSessionConfiguration
  }

  private var syncRoot: URL {
    let base = configuration.directoryURL
    return directoryURL(
      ActivitySyncRemotePath.defaultRootComponents(for: base.lastPathComponent), under: base)
  }

  func list(_ directory: [String]) async throws -> Set<String> {
    guard ActivitySyncRemotePath.validDirectory(directory) else {
      throw ActivitySyncFailure.invalidListing
    }
    let url = directoryURL(directory, under: syncRoot)
    let response = try await request("PROPFIND", url)
    if response.status == 404 { return [] }
    try require(response.status, in: [207])
    return try ActivitySyncDAVListing.children(in: response.data, directory: url, path: directory)
  }

  func read(_ path: [String]) async throws -> Data? {
    guard ActivitySyncRemotePath.validObject(path), let name = path.last else {
      throw ActivitySyncFailure.invalidShard
    }
    let url = directoryURL(path.dropLast(), under: syncRoot).appendingPathComponent(name)
    let limit = ActivitySyncRemotePath.objectByteLimit(path)
    let response = try await request("GET", url, limit: limit)
    if response.status == 404 { return nil }
    try require(response.status, in: [200])
    guard response.data.count <= limit else { throw ActivitySyncFailure.limit }
    return response.data
  }

  func create(_ data: Data, at path: [String]) async throws -> Bool {
    guard ActivitySyncRemotePath.validObject(path),
      !ActivitySyncRemotePath.validMetadataObject(path)
    else { throw ActivitySyncFailure.invalidShard }
    return try await write(data, at: path, creating: true)
  }

  func replaceMetadata(_ data: Data, at path: [String]) async throws {
    guard ActivitySyncRemotePath.validMetadataObject(path) else {
      throw ActivitySyncFailure.invalidShard
    }
    _ = try await write(data, at: path, creating: false)
  }

  private func write(_ data: Data, at path: [String], creating: Bool) async throws -> Bool {
    guard let name = path.last else {
      throw ActivitySyncFailure.invalidShard
    }
    guard data.count <= ActivitySyncRemotePath.objectByteLimit(path)
    else { throw ActivitySyncFailure.limit }
    let root = syncRoot
    let parent = path.dropLast()
    let destination = directoryURL(parent, under: root).appendingPathComponent(name)
    var status = try await request("PUT", destination, body: data, creating: creating).status
    if status == 409 || status == 404 {
      for depth in 0...parent.count
      where depth > 0 || parent.isEmpty || root != configuration.directoryURL {
        let creation = try await request("MKCOL", directoryURL(parent.prefix(depth), under: root))
        try require(creation.status, in: [201, 405])
      }
      status = try await request("PUT", destination, body: data, creating: creating).status
    }
    if creating && status == 412 { return false }
    try require(status, in: [200, 201, 204])
    return true
  }

  private func directoryURL(_ path: some Sequence<String>, under root: URL) -> URL {
    path.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
  }

  private func require(_ status: Int, in accepted: [Int]) throws {
    guard !accepted.contains(status) else { return }
    switch status {
    case 300...399: throw WebDAVError.redirect
    case 401: throw WebDAVError.unauthorized
    case 403: throw WebDAVError.forbidden
    case 404, 409: throw WebDAVError.directoryMissing
    case 423: throw WebDAVError.locked
    case 507: throw WebDAVError.insufficientStorage
    default: throw WebDAVError.http(status)
    }
  }

  private func request(
    _ method: String, _ url: URL, body: Data? = nil, creating: Bool = false,
    limit: Int = ActivitySyncRemotePath.maximumBytes
  )
    async throws -> WebDAVResponse
  {
    try Task.checkCancellation()
    var request = URLRequest(url: url)
    request.httpMethod = method
    let authorization = Data("\(configuration.username):\(password)".utf8).base64EncodedString()
    request.setValue("Basic " + authorization, forHTTPHeaderField: "Authorization")
    request.httpBody = body
    if method == "PROPFIND" {
      request.setValue("1", forHTTPHeaderField: "Depth")
      request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(
        #"<propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>"#.utf8)
    } else if method == "PUT" {
      request.setValue(
        creating ? "application/json" : "application/octet-stream",
        forHTTPHeaderField: "Content-Type")
      if creating { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
    }
    if configuration.endpoint.scheme == "http" {
      return try await httpTransport.send(request, endpoint: configuration.endpoint, limit: limit)
    }
    let options = makeSessionConfiguration()
    options.urlCache = nil
    options.urlCredentialStorage = nil
    options.httpCookieStorage = nil
    options.timeoutIntervalForRequest = 20
    options.timeoutIntervalForResource = 45
    let session = URLSession(configuration: options)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
    guard let http = response as? HTTPURLResponse, http.url == url else {
      throw WebDAVError.transport
    }
    let status = http.statusCode
    guard (method == "GET" && status == 200) || (method == "PROPFIND" && status == 207) else {
      return WebDAVResponse(data: Data(), status: status)
    }
    guard response.expectedContentLength <= limit else { throw ActivitySyncFailure.limit }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw ActivitySyncFailure.limit }
      if data.count.isMultiple(of: 8192) { try Task.checkCancellation() }
      data.append(byte)
    }
    return WebDAVResponse(data: data, status: status)
  }

  final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest
    ) async -> URLRequest? { nil }
  }
}

/// href 仅用来提取直属子项的名称；带凭据的请求始终从已配置的根地址重新构造。
final class ActivitySyncDAVListing: NSObject, XMLParserDelegate {
  let directory: URL
  let path: [String]
  var entries = Set<String>()
  var stack: [String] = []
  var responseCount = 0
  var href = ""
  var status = ""
  var multistatus = false

  init(directory: URL, path: [String]) {
    self.directory = directory
    self.path = path
  }

  static func children(in data: Data, directory: URL, path: [String]) throws -> Set<String> {
    guard data.count <= 1_048_576, let xml = String(data: data, encoding: .utf8),
      !xml.contains("<!"), !xml.utf8.contains(0), ActivitySyncRemotePath.validDirectory(path)
    else { throw ActivitySyncFailure.invalidListing }
    let parser = XMLParser(data: data)
    let listing = ActivitySyncDAVListing(directory: directory, path: path)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = listing
    guard parser.parse(), listing.multistatus, listing.stack.isEmpty else {
      throw ActivitySyncFailure.invalidListing
    }
    return listing.entries
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    stack.append(namespaceURI == "DAV:" ? elementName : "")
    guard stack.count <= 16 else {
      parser.abortParsing()
      return
    }
    switch stack {
    case ["multistatus"]:
      multistatus = true
    case ["multistatus", "response"]:
      responseCount += 1
      if responseCount > ActivitySyncRemotePath.maximumEntries + 1 { parser.abortParsing() }
      href = ""
      status = ""
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    switch stack {
    case ["multistatus", "response", "href"]:
      href += string
      if href.utf8.count > 8192 { parser.abortParsing() }
    case ["multistatus", "response", "status"]:
      status += string
      if status.utf8.count > 256 { parser.abortParsing() }
    default: break
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if stack == ["multistatus", "response"] {
      if !status.isEmpty {
        guard let token = status.split(separator: " ").dropFirst().first, let code = Int(token),
          (200..<300).contains(code)
        else {
          parser.abortParsing()
          return
        }
      }
      if let name = Self.child(href, of: directory, path: path) { entries.insert(name) }
    }
    stack.removeLast()
  }

  static func child(_ href: String, of directory: URL, path: [String]) -> String? {
    let text = href.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("\\"),
      !text.lowercased().contains("%2f"), !text.lowercased().contains("%5c"),
      let decoded = text.removingPercentEncoding,
      !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      let url = URL(string: text, relativeTo: directory)?.absoluteURL,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let base = URLComponents(url: directory, resolvingAgainstBaseURL: true),
      let origin = ActivityDAVEndpoint(directory), ActivityDAVEndpoint(url) == origin,
      parts.query == nil, parts.fragment == nil
    else { return nil }
    let basePath = base.percentEncodedPath
    let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
    let resolvedPath = parts.percentEncodedPath
    guard hasEncodedPrefix(resolvedPath, prefix: prefix) else { return nil }
    var childPath = String(decoding: resolvedPath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    if childPath.hasSuffix("/") {
      childPath.removeLast()
      guard path != [ActivitySyncRemotePath.metadata] else { return nil }
    }
    guard let name = childPath.removingPercentEncoding,
      ActivitySyncRemotePath.validChild(name, in: path)
    else { return nil }
    return name
  }

  private static func hasEncodedPrefix(_ path: String, prefix: String) -> Bool {
    guard path.utf8.count >= prefix.utf8.count else { return false }
    var escapeDigits = 0
    for (actual, expected) in zip(path.utf8, prefix.utf8) {
      if escapeDigits > 0 {
        guard (actual | 0x20) == (expected | 0x20) else { return false }
        escapeDigits -= 1
      } else {
        guard actual == expected else { return false }
        if expected == 0x25 { escapeDigits = 2 }
      }
    }
    return true
  }
}
