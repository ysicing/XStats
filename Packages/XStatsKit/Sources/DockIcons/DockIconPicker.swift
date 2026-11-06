// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Localization

public struct DockIconPicker: View {
  @Binding private var selection: DockIconStyle
  private let product: DockIconProduct
  private let includesAutomatic: Bool

  public init(
    selection: Binding<DockIconStyle>, product: DockIconProduct, includesAutomatic: Bool = false
  ) {
    _selection = selection
    self.product = product
    self.includesAutomatic = includesAutomatic
  }

  public var body: some View {
    HStack(spacing: 8) {
      Image(
        nsImage: selection == .mascot
          ? DockIconRenderer.mascot(for: product) ?? DockIconRenderer.standardIcon
          : DockIconRenderer.standardIcon
      )
      .resizable().scaledToFit().frame(width: 44, height: 44)
      .accessibilityHidden(true)
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
}
