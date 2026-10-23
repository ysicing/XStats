// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 独立手动入口的有界查询；网络诊断会向当前 DNS 查询 apple.com。
public enum EnvironmentPreview {
  @concurrent
  public static func network(
    environment: CleanEnvironment = CleanEnvironment(runningBundleIdentifiers: { [] })
  ) async throws
    -> [SystemCheckFinding]
  {
    var routes: [String] = []
    var routeComplete = true
    for arguments in [["-n", "get", "default"], ["-n", "get", "-inet6", "default"]] {
      try Task.checkCancellation()
      do {
        let result = try await environment.inspectTool("route", arguments)
        if result.status == 0 {
          let observed = result.output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
              ["gateway", "interface"].contains(fields[0].trimmingCharacters(in: .whitespaces)),
              !fields[1].trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
          }
          routes += observed
          if observed.isEmpty { routeComplete = false }
        } else {
          routeComplete = false
        }
      } catch is CancellationError { throw CancellationError() } catch {
        routeComplete = false
      }
    }
    var findings = [
      SystemCheckFinding(
        id: "routes", title: tr("默认路由"),
        status: routes.isEmpty ? .unchecked : .optional,
        isComplete: routeComplete && !routes.isEmpty,
        detail: tr("分别读取 IPv4 与 IPv6 默认路由；缺失一种路由不代表网络故障。"),
        evidence: routes)
    ]
    try Task.checkCancellation()
    do {
      let result = try await environment.inspectTool(
        "dig", ["+time=2", "+tries=1", "+noall", "+answer", "apple.com", "A"])
      try Task.checkCancellation()
      let answers = dnsAnswers(result.output)
      findings.append(
        SystemCheckFinding(
          id: "dnsProbe", title: tr("DNS 单次探测"),
          status: result.status == 0 && !answers.isEmpty ? .normal : .unchecked,
          isComplete: result.status == 0 && !answers.isEmpty,
          detail: tr("仅测试当前 DNS 对 apple.com 的一次解析；代理、过滤或离线均可能影响结果。"),
          evidence: answers))
    } catch is CancellationError { throw CancellationError() } catch {
      findings.append(
        SystemCheckFinding(
          id: "dnsProbe", title: tr("DNS 单次探测"), status: .unchecked, isComplete: false,
          detail: tr("无法完成检查，请稍后重试。")))
    }
    return findings
  }

  @concurrent
  public static func images(
    environment: CleanEnvironment = CleanEnvironment(runningBundleIdentifiers: { [] })
  ) async throws
    -> SystemCheckFinding
  {
    try Task.checkCancellation()
    do {
      let result = try await environment.inspectTool("hdiutil", ["info", "-plist"])
      try Task.checkCancellation()
      guard result.status == 0 else { throw CocoaError(.fileReadUnknown) }
      return try imageFinding(Data(result.output.utf8))
    } catch is CancellationError { throw CancellationError() } catch {
      return SystemCheckFinding(
        id: "images", title: tr("已挂载磁盘映像"), status: .unchecked, isComplete: false,
        detail: tr("无法完成检查，请稍后重试。"))
    }
  }

  static func dnsAnswers(_ output: String) -> [String] {
    output.split(separator: "\n").compactMap { line in
      let columns = line.split(whereSeparator: \.isWhitespace)
      guard columns.count == 5, columns[0] == "apple.com.", UInt32(columns[1]) != nil,
        columns[2] == "IN",
        columns[3] == "A",
        columns[4].split(separator: ".", omittingEmptySubsequences: false).count == 4,
        columns[4].split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
          !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && UInt8($0) != nil
        })
      else { return nil }
      return String(columns[4])
    }
  }

  static func imageFinding(_ data: Data) throws -> SystemCheckFinding {
    guard data.count <= 1_048_576,
      let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let images = dictionary["images"] as? [[String: Any]]
    else { throw CocoaError(.propertyListReadCorrupt) }
    var evidence: [String] = []
    var complete = images.count <= 100
    for image in images.prefix(100) {
      guard let path = image["image-path"] as? String,
        let entities = image["system-entities"] as? [[String: Any]]
      else {
        complete = false
        continue
      }
      // 系统管理的运行时映像不作为手动卸载建议。
      if path.hasPrefix("/System/") || path.hasPrefix("/Library/Developer/CoreSimulator/") {
        continue
      }
      for entity in entities {
        guard let mount = entity["mount-point"] as? String else { continue }
        if evidence.count < 20 { evidence.append(path + " → " + mount) }
      }
    }
    return SystemCheckFinding(
      id: "images", title: tr("已挂载磁盘映像"),
      status: evidence.isEmpty ? complete ? .normal : .unchecked : .optional,
      isComplete: complete,
      detail: tr("展示映像来源与挂载位置；未判断是否闲置，不执行卸载。"),
      evidence: evidence)
  }
}
