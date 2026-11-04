// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct AppManagementUpdateButton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var isUpdating = false
  var isSelected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Text(tr("更新")).hidden()
        Text(tr("更新中…")).hidden()
        Text(isUpdating ? tr("更新中…") : tr("更新"))
          .contentTransition(.opacity)
          .animation(reduceMotion ? nil : DS.Motion.usageSelection, value: isUpdating)
      }
      .dsFont(.sm)
    }
    .buttonStyle(AppManagementUpdateButtonStyle(isSelected: isSelected))
    .controlSize(.small)
    .fixedSize()
  }
}

private struct AppManagementUpdateButtonStyle: ButtonStyle {
  let isSelected: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isSelected ? DS.Palette.primary : .white)
      .padding(.horizontal, DS.Space.s2)
      .padding(.vertical, DS.Space.s1 / 2)
      .background(
        isSelected ? .white : DS.Palette.primary,
        in: RoundedRectangle(cornerRadius: DS.Radius.sm)
      )
      .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.65 : 1)
  }
}
