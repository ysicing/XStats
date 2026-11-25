// SPDX-License-Identifier: AGPL-3.0-or-later

import Charts
import Localization
import SwiftUI

struct ReleaseHighlightsView: View {
  let page: ReleaseHighlightsCatalog.Page
  let maxContentHeight: CGFloat
  var onDone: () -> Void

  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: DS.Space.s3) {
        AppGlyph(size: 44)
          .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        let title =
          page.singleVersion.map { tr("XStats \($0) 新版亮点") } ?? tr("XStats 最近版本亮点")
        Text(title)
          .font(.title.bold())
          .accessibilityAddTraits(.isHeader)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(DS.Space.s6)

      ViewThatFits(in: .vertical) {
        rows
        ScrollView { rows }
      }
      .frame(maxHeight: maxContentHeight)

      Divider()
      HStack(spacing: DS.Space.s3) {
        Button(tr("查看完整更新日志")) {
          openURL(FeedbackLinks.githubRepository.appending(path: "blob/main/CHANGELOG.md"))
        }
        Spacer(minLength: 0)
        Button(tr("完成"), action: onDone)
          .buttonStyle(DSButtonStyle(kind: .primary))
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(DS.Space.s4)
      .padding(.horizontal, DS.Space.s2)
    }
    .frame(width: 540)
    .background(DS.Palette.background)
    .onExitCommand(perform: onDone)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(page.items) { item in
        if item.id != page.items.first?.id, page.singleVersion == nil { Divider() }
        if page.singleVersion != nil && item.feature.showsActivityChart == true {
          HStack(spacing: DS.Space.s4) {
            description(for: item)
              .frame(maxWidth: .infinity, alignment: .leading)
            activityChart
          }
          .padding(DS.Space.s4)
          .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        } else {
          HStack(alignment: .center, spacing: DS.Space.s4) {
            let symbol =
              page.singleVersion == nil
              ? item.feature.symbol : item.feature.singleVersionSymbol ?? item.feature.symbol
            Image(systemName: symbol)
              .font(.system(size: 26, weight: .medium))
              .foregroundStyle(DS.Palette.primary)
              .frame(width: 42)
              .accessibilityHidden(true)
            description(for: item)
          }
          .padding(.vertical, DS.Space.s3)
        }
      }
    }
    .padding(.horizontal, DS.Space.s6)
    .padding(.bottom, DS.Space.s4)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func description(for item: ReleaseHighlightsCatalog.Item) -> some View {
    let copy = item.feature.copy(for: L10n.language)
    let title = Text(verbatim: copy.title).font(.headline)
    let experimental =
      Text(item.feature.experimental == true ? "  \(tr("实验性"))" : "")
      .font(.subheadline)
      .foregroundStyle(.secondary)
    let version = Text(page.singleVersion == nil ? "  \(item.version)" : "")
      .font(.subheadline.monospacedDigit())
      .foregroundStyle(.secondary)
    return VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text("\(title)\(experimental)\(version)").accessibilityAddTraits(.isHeader)
      Text(verbatim: copy.detail)
        .foregroundStyle(.secondary)
    }
    .environment(\.layoutDirection, .leftToRight)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var activityChart: some View {
    let demoWeek = [
      [3, 2, 1], [5, 2, 1], [5, 3, 2], [4, 3, 1], [3, 1, 1], [4, 2, 1], [5, 2, 2],
    ]
    let colors = [DS.Palette.primary, Color.teal, Color.secondary.opacity(0.45)]
    return VStack(alignment: .trailing, spacing: DS.Space.s1) {
      Chart {
        ForEach(demoWeek.indices, id: \.self) { day in
          ForEach(demoWeek[day].indices, id: \.self) { category in
            BarMark(
              x: .value("Day", day), y: .value("Hours", demoWeek[day][category]), width: .fixed(16)
            )
            .foregroundStyle(colors[category])
          }
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .frame(width: 154, height: 70)
      Text(tr("示例数据"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityHidden(true)
  }
}
