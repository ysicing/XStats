// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

struct MoleCommandView: View {
  let controller: MoleController
  let nativeBusy: Bool
  var installation = false
  @State private var followsOutput = true

  var body: some View {
    @Bindable var mole = controller
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack(spacing: DS.Space.s2) {
        if installation {
          Button(tr("安装 Mole")) { mole.install() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!mole.canInstall)
        } else {
          Button(tr("仅预览")) { mole.scan() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!mole.canStart || nativeBusy)
          Button(
            mole.workflow == .clean ? tr("使用 Mole 清理") : tr("使用 Mole 优化"),
            role: .destructive
          ) { mole.requestExecution() }
          .buttonStyle(DSButtonStyle(kind: .primary))
          .disabled(!mole.canExecute || nativeBusy)
          .confirmationDialog(
            mole.workflow == .clean ? tr("使用 Mole 清理？") : tr("使用 Mole 优化？"),
            isPresented: $mole.isConfirming, titleVisibility: .visible
          ) {
            Button(
              mole.workflow == .clean ? tr("执行 mo clean") : tr("执行 mo optimize"),
              role: .destructive
            ) { mole.confirmExecution() }
            Button(tr("取消"), role: .cancel) { mole.cancelConfirmation() }
          } message: {
            Text(
              mole.workflow == .clean
                ? tr(
                  "将执行 mo clean，按 Mole 自己的规则重新扫描并永久删除文件。XStats 的勾选、保留项目和移到废纸篓设置不适用于 Mole；扫描结果不是固定清单。没有可用管理员授权时，Mole 会跳过系统级清理。"
                )
                : tr(
                  "将执行 mo optimize，由 Mole 决定并应用优化。预览不是固定执行清单，Mole 可能请求管理员授权。停止不能撤销已完成的更改。"
                ))
          }
        }
        if mole.isRunning {
          Button(mole.isCancelling ? tr("正在停止…") : tr("停止")) { mole.cancel() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(mole.isCancelling)
        }
        Spacer(minLength: 0)
        if mole.isRunning { ProgressView().controlSize(.small) }
      }
      if !installation {
        Text(
          mole.workflow == .clean
            ? tr("预览执行 mo clean --dry-run，不删除文件；清理执行 mo clean。")
            : tr("预览执行 mo optimize --dry-run，不应用更改；优化执行 mo optimize。")
        )
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      if let command = mole.lastCommand {
        HStack {
          Text(verbatim: "$ " + command.displayCommand).monospaced()
          Spacer()
          Text(status).foregroundStyle(isFailure ? DS.Palette.warning : DS.Palette.textSecondary)
        }
        .dsFont(.xs)
      }
      if let failure = mole.failure {
        Text(verbatim: failure).dsFont(.xs).foregroundStyle(DS.Palette.warning)
      }
      if mole.outputWasTruncated {
        Text(tr("日志较长，仅保留最近 128 KiB。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      if mole.lastCommand != nil { executionLog }
    }
    .padding(DS.Space.s3)
  }

  private var executionLog: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        Text(tr("执行日志")).dsFont(.xs, weight: .semibold)
        Spacer()
        Toggle(tr("跟随输出"), isOn: $followsOutput).toggleStyle(.checkbox).fixedSize()
      }
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: controller.output)
              .font(.system(size: DS.TextSize.xs.rawValue, design: .monospaced))
              .textSelection(.enabled)
            Color.clear.frame(height: 1).id("end")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(DS.Space.s3)
        }
        .environment(\.layoutDirection, .leftToRight)
        // 日志区按需挂载，快速命令可能在首次显示前已输出完毕。
        .onChange(of: controller.output, initial: true) { _, _ in
          if followsOutput { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
  }

  private var isFailure: Bool {
    controller.failure != nil || (controller.exitStatus ?? 0) != 0
  }

  private var status: String {
    let mole = controller
    if mole.isCancelling { return tr("正在停止…") }
    if mole.isRunning { return tr("执行中") }
    if mole.wasCancelled {
      if mole.lastCommand == .install { return tr("安装已停止") }
      if mole.lastCommand?.isPreview == true { return tr("预览已取消") }
      return mole.lastCommand == .clean
        ? tr("已停止，已清理部分不会恢复") : tr("已停止，已完成的优化不会撤销")
    }
    if let code = mole.exitStatus { return tr("命令已退出（退出码 \(code)）") }
    return tr("命令未能启动")
  }
}
