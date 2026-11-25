// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import WebDAVSync

struct ActivitySyncWebDAV: ActivitySyncRepository {
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

  private var root: URL {
    configuration.directoryURL.appendingPathComponent(
      ActivitySyncRemotePath.namespace, isDirectory: true)
  }

  func list(_ directory: [String]) async throws -> Set<String> {
    guard ActivitySyncRemotePath.validDirectory(directory) else {
      throw ActivitySyncFailure.invalidListing
    }
    let url = directoryURL(directory)
    let response = try await request("PROPFIND", url)
    if response.status == 404 { return [] }
    try require(response.status, in: [207])
    return try ActivitySyncDAVListing.children(in: response.data, directory: url, path: directory)
  }

  func read(_ path: [String]) async throws -> Data? {
    guard ActivitySyncRemotePath.validObject(path), let name = path.last else {
      throw ActivitySyncFailure.invalidShard
    }
    let url = directoryURL(path.dropLast()).appendingPathComponent(name)
    let response = try await request("GET", url)
    if response.status == 404 { return nil }
    try require(response.status, in: [200])
    return response.data
  }

  func create(_ data: Data, at path: [String]) async throws -> Bool {
    guard ActivitySyncRemotePath.validObject(path), let name = path.last else {
      throw ActivitySyncFailure.invalidShard
    }
    guard data.count <= ActivitySyncRemotePath.maximumBytes else { throw ActivitySyncFailure.limit }
    let parent = path.dropLast()
    let destination = directoryURL(parent).appendingPathComponent(name)
    var status = try await request("PUT", destination, body: data).status
    if status == 409 || status == 404 {
      for depth in 0...parent.count {
        let creation = try await request("MKCOL", directoryURL(parent.prefix(depth)))
        try require(creation.status, in: [201, 405])
      }
      status = try await request("PUT", destination, body: data).status
    }
    if status == 412 { return false }
    try require(status, in: [200, 201, 204])
    return true
  }

  private func directoryURL(_ path: some Sequence<String>) -> URL {
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

  private func request(_ method: String, _ url: URL, body: Data? = nil)
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
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("*", forHTTPHeaderField: "If-None-Match")
    }
    let limit = method == "GET" ? ActivitySyncRemotePath.maximumBytes : 1_048_576
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
    guard !text.isEmpty, !text.contains("\\"), !text.contains("%25"),
      !text.lowercased().contains("%2f"), !text.lowercased().contains("%5c"),
      let decoded = text.removingPercentEncoding,
      !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      let url = URL(string: text, relativeTo: directory)?.absoluteURL,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let origin = ActivityDAVEndpoint(directory), ActivityDAVEndpoint(url) == origin,
      parts.query == nil, parts.fragment == nil
    else { return nil }
    let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    guard parts.path.hasPrefix(prefix) else { return nil }
    var name = String(parts.path.dropFirst(prefix.count))
    if name.hasSuffix("/") { name.removeLast() }
    guard ActivitySyncRemotePath.validChild(name, in: path) else { return nil }
    return name
  }
}
