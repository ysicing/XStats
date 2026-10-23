// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

@Suite struct AddressFamilyRequestTests {
  @Test(arguments: [
    "-1", "-0", String(Int.min), "+2", "", "two", "2x", "2.0", "1 0", "2, 2", "٢",
    String(Int.max) + "0",
  ])
  func rejectsInvalidContentLength(_ length: String) {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(length)\r\n\r\n{}".utf8)
    let (body, status) = AddressFamilyRequest.parse(response)
    #expect(body == nil)
    #expect(status == 200)
  }

  @Test func validatesEveryContentLengthHeader() {
    for lengths in ["-1\r\nContent-Length: 2", "3\r\nContent-Length: 2"] {
      let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(lengths)\r\n\r\n{}".utf8)
      #expect(AddressFamilyRequest.parse(response).0 == nil)
    }
    let chunked = Data(
      "HTTP/1.1 200 OK\r\nContent-Length: invalid\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        .utf8)
    #expect(AddressFamilyRequest.parse(chunked).0 == nil)
  }

  @Test(arguments: [
    ("0", ""), ("0002", "{}"), ("2\r\nContent-Length: 2", "{}"),
  ])
  func acceptsValidContentLength(_ length: String, expected: String) {
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(length)\r\n\r\n{}extra".utf8)
    #expect(AddressFamilyRequest.parse(response).0 == Data(expected.utf8))
  }

  @Test func missingLengthUsesConnectionDelimitedBody() {
    let response = Data("HTTP/1.1 200 OK\r\n\r\n{}".utf8)
    #expect(AddressFamilyRequest.parse(response).0 == Data("{}".utf8))
  }

  @Test(arguments: [
    "-1", "-0", "+1", "", ";1", "g", "0x1", "1 0", " 1", String(Int.max, radix: 16) + "0",
  ])
  func rejectsInvalidChunkSize(_ size: String) {
    let response = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\na\r\n0\r\n\r\n".utf8)
    let (body, status) = AddressFamilyRequest.parse(response)
    #expect(body == nil)
    #expect(status == 200)
  }

  @Test func rejectsTruncatedOrUnterminatedChunk() {
    #expect(AddressFamilyRequest.dechunk(Data("2\r\na".utf8)) == nil)
    #expect(AddressFamilyRequest.dechunk(Data("1\r\naXX0\r\n\r\n".utf8)) == nil)
    #expect(AddressFamilyRequest.dechunk(Data("\(String(Int.max, radix: 16))\r\na".utf8)) == nil)
  }

  @Test func acceptsHexadecimalChunksWithExtensions() {
    let body = Data("A;x=1\r\n0123456789\r\n0\r\n\r\n".utf8)
    #expect(AddressFamilyRequest.dechunk(body) == Data("0123456789".utf8))
    let spaced = Data("A \t;x=1\r\n0123456789\r\n0 ;end\r\n\r\n".utf8)
    #expect(AddressFamilyRequest.dechunk(spaced) == Data("0123456789".utf8))
  }
}
