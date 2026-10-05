// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import SwiftUI

/// 速率作为紧凑的一组信息，方向、数值与单位紧邻，避免短读数被拉成稀疏的两列。
struct OverviewNetworkRates: View {
    let download: String
    let upload: String
    private enum Direction: Hashable { case download, upload }

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            ForEach([Direction.download, .upload], id: \.self) { direction in
                let isDownload = direction == .download
                let rate = isDownload ? download : upload
                let parts = rate.split(separator: " ", maxSplits: 1).map(String.init)
                let title = isDownload ? tr("下载") : tr("上传")
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                    Image(systemName: isDownload ? "arrow.down" : "arrow.up")
                        .dsFont(.xs, weight: .semibold)
                        .foregroundStyle(Color(nsColor: isDownload ? DS.NetworkPalette.download : DS.NetworkPalette.upload))
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                        Text(verbatim: parts.first ?? "—")
                            .dsFont(.sm, weight: .semibold)
                            .foregroundStyle(DS.Palette.textPrimary)
                        if parts.count > 1 {
                            Text(verbatim: parts[1]).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(rate)
                .help(title)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
