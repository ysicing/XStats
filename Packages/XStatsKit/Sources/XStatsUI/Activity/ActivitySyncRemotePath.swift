// SPDX-License-Identifier: AGPL-3.0-or-later

enum ActivitySyncRemotePath {
  static let namespace = "XStats-Activity-v2"
  static let marker = "dataset"
  static let maximumBytes = 1_048_576
  static let maximumEntries = 2048

  static func validDirectory(_ path: [String]) -> Bool {
    path.count <= 2 && path.allSatisfy { isHex($0, count: 48) }
  }

  static func validObject(_ path: [String]) -> Bool {
    guard let name = path.last else { return false }
    let parent = Array(path.dropLast())
    guard validDirectory(parent) else { return false }
    return parent.isEmpty ? name == marker : parent.count == 2 && isHex(name, count: 128)
  }

  static func validChild(_ name: String, in directory: [String]) -> Bool {
    guard validDirectory(directory) else { return false }
    switch directory.count {
    case 0: return name == marker || isHex(name, count: 48)
    case 1: return isHex(name, count: 48)
    case 2: return isHex(name, count: 128)
    default: return false
    }
  }

  private static func isHex(_ name: String, count: Int) -> Bool {
    name.utf8.prefix(count + 1).count == count
      && name.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
      }
  }
}
