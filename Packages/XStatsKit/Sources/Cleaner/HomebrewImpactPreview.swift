// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct HomebrewImpactPreview: Sendable, Equatable {
  public let package: HomebrewPackage
  public let action: HomebrewManagement.Action
  public let output: String
  public let dependents: [String]
  public var canProceed: Bool { action == .upgrade || dependents.isEmpty }

  public init(
    package: HomebrewPackage, action: HomebrewManagement.Action,
    output: String, dependents: [String] = []
  ) {
    self.package = package
    self.action = action
    self.output = output
    self.dependents = dependents
  }
}

extension HomebrewManagement {
  /// 预览只在用户打开确认面板时读取，不刷新索引；环境与真实操作保持一致。
  @concurrent
  public static func preview(
    _ action: Action, package: HomebrewPackage, home: String = NSHomeDirectory()
  ) async throws -> HomebrewImpactPreview {
    let packages = try await inventory(home: home, requiresCompleteInventory: true)
    return try await preview(action, package: package, inventory: packages) { arguments in
      try await DeveloperToolRunner.run(
        "brew", arguments: arguments, home: home,
        environmentOverrides: ["HOMEBREW_NO_INSTALL_CLEANUP": "1"],
        outputLimit: 256_000, includesStandardError: false
      ).output
    }
  }

  static func preview(
    _ action: Action, package: HomebrewPackage, inventory: [HomebrewPackage],
    run: @Sendable ([String]) async throws -> String
  ) async throws -> HomebrewImpactPreview {
    let command = try arguments(for: action, package: package)
    guard inventory.contains(package) else { throw InventoryError.invalidPackage }
    try Task.checkCancellation()
    if action == .upgrade {
      guard package.outdated else { throw InventoryError.invalidPackage }
      var arguments = command
      arguments.insert("--dry-run", at: 1)
      let output = try await run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
      try Task.checkCancellation()
      guard !output.isEmpty else { throw InventoryError.invalidOutput }
      return HomebrewImpactPreview(package: package, action: action, output: output)
    }
    let dependents: [String]
    if package.kind == .formula {
      let output = try await run(["uses", "--installed", "--recursive", package.name])
      dependents = try parseDependents(output)
    } else {
      dependents = try caskDependents(of: package, in: inventory)
    }
    try Task.checkCancellation()
    return HomebrewImpactPreview(
      package: package, action: action, output: "", dependents: dependents)
  }

  static func parseDependents(_ output: String) throws -> [String] {
    let names = output.split(whereSeparator: \.isWhitespace).map(String.init)
    guard names.count <= 10_000, names.allSatisfy(validToken) else {
      throw InventoryError.invalidOutput
    }
    return Set(names).sorted()
  }

  /// uses 仅接受 Formula。Cask 从完整清单的 depends_on.cask 反向遍历，
  /// 短名有歧义或任一依赖字段损坏时拒绝预览，不能把未知误报成没有依赖方。
  static func caskDependents(
    of package: HomebrewPackage, in inventory: [HomebrewPackage]
  ) throws -> [String] {
    let casks = inventory.filter { $0.kind == .cask }
    let byName = Dictionary(casks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let byShortName = Dictionary(grouping: casks) {
      $0.name.split(separator: "/").last.map(String.init) ?? $0.name
    }
    var reverse: [String: Set<String>] = [:]
    for cask in casks {
      try Task.checkCancellation()
      guard let dependencies = cask.caskDependencies else { throw InventoryError.invalidOutput }
      for dependency in dependencies {
        let matches =
          dependency.contains("/")
          ? byName[dependency].map { [$0] } ?? [] : byShortName[dependency] ?? []
        guard matches.count == 1, let installed = matches.first else {
          throw InventoryError.invalidOutput
        }
        reverse[installed.name, default: []].insert(cask.name)
      }
    }
    var visited: Set<String> = [package.name]
    var pending = [package.name]
    while let name = pending.popLast() {
      try Task.checkCancellation()
      for dependent in reverse[name] ?? [] where visited.insert(dependent).inserted {
        pending.append(dependent)
      }
    }
    visited.remove(package.name)
    return visited.sorted()
  }
}
