// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public struct SystemCheckFinding: Sendable, Identifiable {
  public enum Status: Sendable { case normal, attention, optional, notApplicable, unchecked }

  public let id: String
  public let title: String
  public let status: Status
  public let isComplete: Bool
  public let detail: String
  public let evidence: [String]

  public init(
    id: String, title: String, status: Status, isComplete: Bool = true,
    detail: String, evidence: [String] = []
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.isComplete = isComplete
    self.detail = detail
    self.evidence = Array(evidence.prefix(20)).map { String($0.prefix(500)) }
  }
}

public enum SystemCheck {
  public static func homebrew(environment: CleanEnvironment) async throws -> SystemCheckFinding {
    try Task.checkCancellation()
    guard environment.isToolAvailable("brew") else {
      return SystemCheckFinding(
        id: "brewAutoremove", title: "Homebrew", status: .notApplicable,
        detail: tr("未安装 Homebrew"))
    }
    do {
      let result = try await environment.inspectTool("brew", ["autoremove", "--dry-run"])
      try Task.checkCancellation()
      guard result.status == 0 else {
        throw ToolExecutionError.failed(
          tool: "brew", status: result.status, output: "")
      }
      let lines = result.output.split(separator: "\n")
      let complete = lines.count <= 20 && lines.prefix(20).allSatisfy { $0.count <= 500 }
      return SystemCheckFinding(
        id: "brewAutoremove", title: tr("Homebrew 依赖预览"), status: .optional,
        isComplete: complete,
        detail: complete
          ? tr("由 Homebrew 列出不再需要的依赖，仅供审阅。")
          : tr("预览内容过长，仅显示部分结果。"),
        evidence: lines.prefix(20).map(String.init))
    } catch is CancellationError { throw CancellationError() } catch {
      return SystemCheckFinding(
        id: "brewAutoremove", title: tr("Homebrew 依赖预览"), status: .unchecked,
        isComplete: false, detail: tr("无法完成检查，请稍后重试。"))
    }
  }
}
