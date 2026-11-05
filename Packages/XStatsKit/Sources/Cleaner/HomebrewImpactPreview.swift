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
    // 预览要求目标仍在清单中；只有操作后的缺失核验才要求完整识别所有 Formula。
    let packages = try await inventory(home: home)
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

  /// uses 仅接受 Formula。Cask 从完整清单的 depends_on.cask 反向遍历，并用 old_tokens 识别改名前的依赖。
  /// 依赖或旧名称字段损坏时拒绝预览；依赖名无法唯一匹配时，只有可能指向目标或其传递依赖方才拒绝，
  /// 其余无关的未命中或歧义边不影响本次预览，也不能把未知误报成没有依赖方。
  static func caskDependents(
    of package: HomebrewPackage, in inventory: [HomebrewPackage]
  ) throws -> [String] {
    let casks = inventory.filter { $0.kind == .cask }
    var byName: [String: Set<String>] = [:]
    var byShortName: [String: Set<String>] = [:]
    for cask in casks {
      try Task.checkCancellation()
      guard let oldTokens = cask.caskOldTokens else { throw InventoryError.invalidOutput }
      for token in [cask.name] + oldTokens {
        let fullToken: String
        if !token.contains("/"), let separator = cask.name.lastIndex(of: "/") {
          fullToken = String(cask.name[...separator]) + token
        } else {
          fullToken = token
        }
        byName[fullToken, default: []].insert(cask.name)
        let shortToken = token.split(separator: "/").last.map(String.init) ?? token
        byShortName[shortToken, default: []].insert(cask.name)
      }
    }
    var reverse: [String: Set<String>] = [:]
    var ambiguous: [Set<String>] = []
    for cask in casks {
      try Task.checkCancellation()
      guard let dependencies = cask.caskDependencies else { throw InventoryError.invalidOutput }
      for dependency in dependencies {
        let matches =
          dependency.contains("/")
          ? byName[dependency] ?? [] : byShortName[dependency] ?? []
        if matches.count == 1, let installed = matches.first {
          reverse[installed, default: []].insert(cask.name)
        } else if matches.count > 1 {
          ambiguous.append(matches)
        }
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
    if ambiguous.contains(where: { !$0.isDisjoint(with: visited) }) {
      throw InventoryError.invalidOutput
    }
    visited.remove(package.name)
    return visited.sorted()
  }
}
