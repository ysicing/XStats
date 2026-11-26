// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum ActivityReportExport {
  enum Format: String, Sendable {
    case markdown = "md"
    case csv
  }

  static func render(
    _ report: ActivityPageAnalytics, format: Format, interval: DateInterval,
    period: ActivityPagePeriod, deviceName: String, calendar: Calendar, locale: Locale,
    language: AppLanguage
  ) -> String {
    let translate: (String) -> String = { L10n.translate($0, language: language) }
    let dateStyle = Date.FormatStyle(
      locale: locale, calendar: calendar, timeZone: calendar.timeZone
    ).year().month().day()
    let first = interval.start.formatted(dateStyle)
    let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
    let dateRange =
      calendar.isDate(interval.start, inSameDayAs: last)
      ? first : "\(first) – \(last.formatted(dateStyle))"
    let metadata = [
      (translate("统计周期"), translate(period.titleSource)),
      (translate("时间范围"), dateRange),
      (translate("设备"), deviceName),
    ]
    let total = translate("总活跃时长")
    let categoryTitle = translate("分类")
    let name = translate("名称")
    let categories = translate("分类汇总")
    let apps = translate("应用排行")

    switch format {
    case .markdown:
      let duration: (TimeInterval) -> String = { ActivityPageFormat.duration($0, locale: locale) }
      let activeTime = translate("活跃时长")
      var lines = ["# \(markdown(translate("活动报表")))", ""]
      lines += metadata.map { "- \(markdown($0.0)) · \(markdown($0.1))" }
      lines += [
        "- \(markdown(total)) · \(markdown(duration(report.seconds)))",
        "",
        "## \(markdown(categories))",
        "",
        markdownRow([categoryTitle, activeTime]),
        "| --- | ---: |",
      ]
      lines += report.categories.map {
        markdownRow([translate($0.id.titleSource), duration($0.seconds)])
      }
      lines += [
        "",
        "## \(markdown(apps))",
        "",
        markdownRow([name, categoryTitle, activeTime]),
        "| --- | --- | ---: |",
      ]
      lines += report.apps.map {
        markdownRow([$0.name, translate($0.category.titleSource), duration($0.seconds)])
      }
      return lines.joined(separator: "\n") + "\n"
    case .csv:
      var lines = [
        csvRow([translate("类型"), name, categoryTitle, translate("活跃时长（秒）")])
      ]
      lines += metadata.map { csvRow([$0.0, $0.1, "", ""]) }
      lines.append(csvRow([total, "", "", String(report.seconds)]))
      lines += report.categories.map {
        csvRow([categories, "", translate($0.id.titleSource), String($0.seconds)])
      }
      lines += report.apps.map {
        csvRow([apps, $0.name, translate($0.category.titleSource), String($0.seconds)])
      }
      return lines.joined(separator: "\r\n") + "\r\n"
    }
  }

  private static func markdownRow(_ fields: [String]) -> String {
    "| " + fields.map(markdown).joined(separator: " | ") + " |"
  }

  private static func markdown(_ value: String) -> String {
    let punctuation = Set("\\`*_{}[]<>()#+-.!|~&")
    var escaped = ""
    for character in value {
      if character.isNewline {
        escaped.append(" ")
      } else {
        if punctuation.contains(character) { escaped.append("\\") }
        escaped.append(character)
      }
    }
    return escaped
  }

  private static func csvRow(_ fields: [String]) -> String {
    fields.map { field in
      // 设备名和应用名可能来自同步，避免表格软件将其作为公式执行。
      let first = field.drop(while: \.isWhitespace).first
      let safe = first.map { "=+-@".contains($0) } == true ? "'" + field : field
      return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }.joined(separator: ",")
  }
}
