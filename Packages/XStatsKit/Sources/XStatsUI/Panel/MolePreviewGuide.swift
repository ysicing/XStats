// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct MolePreviewGuide: View {
  let command: String
  let detail: String
  @State private var copied = false

  var body: some View {
    InfoBanner(icon: "terminal", text: detail) {
      HStack(spacing: DS.Space.s2) {
        Text(verbatim: command)
          .dsFont(.xs)
          .monospaced()
          .textSelection(.enabled)
          .environment(\.layoutDirection, .leftToRight)
        Button(copied ? tr("已拷贝") : tr("复制命令")) {
          NSPasteboard.general.clearContents()
          copied = NSPasteboard.general.setString(command, forType: .string)
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .accessibilityLabel(tr("复制命令"))
      }
      .fixedSize()
    }
  }
}
