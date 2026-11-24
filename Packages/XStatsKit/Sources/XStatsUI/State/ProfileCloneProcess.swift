// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

enum ProfileCloneProcess {
  static func isUsingProfile(_ profile: URL, pids: [pid_t]) -> Bool {
    let directory = profile.resolvingSymlinksInPath().standardizedFileURL.path
    return pids.contains { pid in
      guard pid > 0 else { return false }
      guard let arguments = arguments(for: pid) else {
        return kill(pid, 0) == 0 || errno == EPERM
      }
      return profilePaths(in: arguments).contains {
        $0 == directory || $0.hasPrefix(directory + "/")
      }
    }
  }

  static func profilePaths(in arguments: [String]) -> Set<String> {
    let profileOptions: Set<String> = ["--user-data-dir", "--extensions-dir", "-profile"]
    return Set(
      arguments.indices.compactMap { index in
        let parts = arguments[index].split(
          separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let option = parts.first, profileOptions.contains(String(option)) else { return nil }
        let path: String
        if parts.count == 2 {
          path = String(parts[1])
        } else if arguments.indices.contains(index + 1) {
          path = arguments[index + 1]
        } else {
          return nil
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
      })
  }

  private static func arguments(for pid: pid_t) -> [String]? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var length = 0
    guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0,
      length > MemoryLayout<Int32>.size, length <= 1_048_576
    else { return nil }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
    return decodeArguments(buffer.prefix(length))
  }

  static func decodeArguments(_ buffer: ArraySlice<UInt8>) -> [String]? {
    let headerLength = MemoryLayout<Int32>.size
    guard buffer.count > headerLength else { return nil }
    let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard count > 0, count <= buffer.count,
      let executableEnd = buffer.dropFirst(headerLength).firstIndex(of: 0),
      let argumentsStart = buffer[executableEnd...].firstIndex(where: { $0 != 0 })
    else { return nil }

    var remaining = buffer[argumentsStart...]
    var arguments: [String] = []
    for _ in 0..<count {
      guard let end = remaining.firstIndex(of: 0) else { return nil }
      arguments.append(String(decoding: remaining[..<end], as: UTF8.self))
      remaining = remaining[(end + 1)...]
    }
    return arguments
  }
}
