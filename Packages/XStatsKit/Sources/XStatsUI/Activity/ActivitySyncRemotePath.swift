// SPDX-License-Identifier: AGPL-3.0-or-later

enum ActivitySyncRemotePath {
  static let namespace = "XStats"
  static let marker = "dataset"
  static let metadata = "metadata"
  static let maximumBytes = 1_048_576
  static let maximumEntries = 2048
  static let maximumMetadataBytes = 64 * 1024
  static let maximumMetadataEntries = 128

  static func defaultRootComponents(for selectedName: String) -> [String] {
    selectedName == namespace ? [] : [namespace]
  }

  static func validDirectory(_ path: [String]) -> Bool {
    path == [metadata] || validShardDirectory(path)
  }

  static func validShardDirectory(_ path: [String]) -> Bool {
    path.count <= 2 && path.allSatisfy { isHex($0, count: 48) }
  }

  static func validObject(_ path: [String]) -> Bool {
    switch path.count {
    case 1: return path[0] == marker
    case 2: return validMetadataObject(path)
    case 3: return validChild(path[2], in: Array(path.dropLast()))
    default: return false
    }
  }

  static func validMetadataObject(_ path: [String]) -> Bool {
    path.count == 2 && path[0] == metadata && validChild(path[1], in: [metadata])
  }

  static func objectByteLimit(_ path: [String]) -> Int {
    validMetadataObject(path) ? maximumMetadataBytes : maximumBytes
  }

  static func validChild(_ name: String, in directory: [String]) -> Bool {
    if directory == [metadata] { return isHex(name, count: 64) }
    guard validDirectory(directory) else { return false }
    switch directory.count {
    case 0: return name == marker || name == metadata || isHex(name, count: 48)
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
