// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// `brew services list --json` 的公开字段，不把 Formula 安装清单当作服务清单。
public struct HomebrewService: Decodable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  public let name: String
  public let status: String
  public let user: String?
  public let file: String?
  public let exitCode: Int?

  enum CodingKeys: String, CodingKey {
    case name, status, user, file
    case exitCode = "exit_code"
  }

  public func canManage(currentUser: String = NSUserName()) -> Bool {
    guard user != "root" else { return false }
    // root 服务可能配置为其他用户运行，不能只看 UserName 就把系统域服务当作用户服务。
    if let file,
      URL(fileURLWithPath: file).standardizedFileURL.path.hasPrefix("/Library/LaunchDaemons/")
    {
      return false
    }
    return user == nil || user == currentUser
  }
}

public enum HomebrewServices {
  public enum Action: String, CaseIterable, Sendable { case start, stop, restart }

  public enum ServiceError: Error, LocalizedError {
    case invalidOutput, unavailableService

    public var errorDescription: String? {
      switch self {
      case .invalidOutput: tr("无法识别 Homebrew 服务列表")
      case .unavailableService: tr("服务已变化或不属于当前用户，请刷新后重试")
      }
    }
  }

  @concurrent
  public static func inventory() async throws -> [HomebrewService] {
    let result = try await DeveloperToolRunner.run(
      "brew", arguments: ["services", "list", "--json"], home: NSHomeDirectory(),
      previewTimeout: 30, outputLimit: 2_000_000, includesStandardError: false)
    try Task.checkCancellation()
    return try parse(result.output)
  }

  public static func parse(_ output: String) throws -> [HomebrewService] {
    guard output.utf8.count <= 2_000_000,
      let services = try? JSONDecoder().decode([HomebrewService].self, from: Data(output.utf8)),
      services.count <= 10_000
    else { throw ServiceError.invalidOutput }
    var names = Set<String>()
    for service in services {
      try Task.checkCancellation()
      // 无法唯一识别服务时整体报错，不让截断或重复的清单提供错误操作目标。
      guard validName(service.name), !service.status.isEmpty,
        names.insert(service.name).inserted
      else { throw ServiceError.invalidOutput }
    }
    return services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public static func perform(_ action: Action, service: HomebrewService) async throws {
    // 操作前重新核对归属；页面打开后服务可能已被终端移到系统域或卸载。
    let current = try await inventory()
    let arguments = try arguments(for: action, service: service, current: current)
    _ = try await DeveloperToolRunner.run(
      "brew", arguments: arguments, home: NSHomeDirectory(), previewTimeout: 90)
  }

  static func arguments(
    for action: Action, service: HomebrewService, current: [HomebrewService],
    currentUser: String = NSUserName()
  ) throws -> [String] {
    guard validName(service.name),
      let fresh = current.first(where: { $0.name == service.name }),
      fresh.canManage(currentUser: currentUser)
    else { throw ServiceError.unavailableService }
    // 不提权、不使用 --all，服务名始终是独立参数。
    return ["services", action.rawValue, fresh.name]
  }

  private static func validName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 255 else { return false }
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+_.-")
    return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && $0.first != "-"
        && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
  }
}
