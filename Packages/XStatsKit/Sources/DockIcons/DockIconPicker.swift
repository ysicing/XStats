// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Localization

public struct DockIconPicker: View {
  @Binding private var selection: DockIconStyle
  private let includesAutomatic: Bool

  public init(
    selection: Binding<DockIconStyle>, includesAutomatic: Bool = false
  ) {
    _selection = selection
    self.includesAutomatic = includesAutomatic
  }

  public var body: some View {
    Picker(tr("程序坞图标"), selection: $selection) {
      ForEach(
        DockIconStyle.allCases.filter { includesAutomatic || $0 != .automatic }, id: \.rawValue
      ) {
        Text($0.title).tag($0)
      }
    }
    .labelsHidden()
    .fixedSize()
  }
}
