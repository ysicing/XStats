// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

struct MoleCommandView: View {
  let controller: MoleController
  let nativeBusy: Bool
  var installation = false
  @State private var followsOutput = true
  @State private var logContentHeight: CGFloat = 48

  var showsIntroduction: Bool {
    !installation && !showsExecutionLog
  }

  var showsExecutionLog: Bool {
    guard let command = controller.lastCommand else { return false }
    // 安装与工作流复用执行器，日志只在对应界面展示，避免安装结果混进清理或优化。
    return installation == (command == .install)
  }

  var body: some View {
    @Bindable var mole = controller
    Group {
      if showsIntroduction {
        introduction.transition(.opacity)
      } else {
        commandContent.transition(.opacity)
      }
    }
    .padding(DS.Space.s3)
    .dsSelectionAnimation(DS.Motion.quick, value: showsIntroduction)
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

  private var introduction: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: DS.Space.s4) {
          Image(systemName: controller.workflow == .clean ? "trash" : "wrench.and.screwdriver")
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(DS.Palette.textSecondary)
            .accessibilityHidden(true)
          VStack(spacing: DS.Space.s2) {
            Text(controller.workflow == .clean ? tr("使用 Mole 清理") : tr("使用 Mole 优化"))
              .dsFont(.xl, weight: .semibold)
              .accessibilityAddTraits(.isHeader)
            Text(
              controller.workflow == .clean
                ? tr("可先预览清理范围，也可直接开始清理。")
                : tr("可先预览优化项目，也可直接开始优化。")
            )
            .dsFont(.sm)
            .foregroundStyle(DS.Palette.textSecondary)
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          workflowActions
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Space.s4)
        .padding(.top, max(DS.Space.s4, geometry.size.height * 0.22))
        .padding(.bottom, DS.Space.s4)
      }
    }
  }

  private var workflowActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DS.Space.s2) { workflowButtons }.fixedSize()
      VStack(spacing: DS.Space.s2) { workflowButtons }
    }
  }

  @ViewBuilder
  private var workflowButtons: some View {
    Button(tr("仅预览")) { controller.scan() }
      .buttonStyle(DSButtonStyle(kind: .secondary))
      .disabled(!controller.canStart || nativeBusy)
      .help(
        controller.workflow == .clean
          ? tr("查看清理范围，不删除文件") : tr("查看优化项目，不应用更改"))
    Button(
      controller.workflow == .clean ? tr("开始清理") : tr("开始优化"),
      role: .destructive
    ) { controller.requestExecution() }
    .buttonStyle(DSButtonStyle(kind: .primary))
    .disabled(!controller.canExecute || nativeBusy)
  }

  private var commandContent: some View {
    let mole = controller
    return VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack(spacing: DS.Space.s2) {
        if installation {
          Button(tr("安装 Mole")) { mole.install() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!mole.canInstall)
        } else {
          workflowActions
        }
        if mole.isRunning {
          Button(mole.isCancelling ? tr("正在停止…") : tr("停止")) { mole.cancel() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(mole.isCancelling)
        }
        Spacer(minLength: 0)
        if mole.isRunning { ProgressView().controlSize(.small) }
      }
      if showsExecutionLog {
        executionLog.transaction { $0.animation = nil }
      }
    }
  }

  private var executionLog: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
        Text(tr("执行日志")).dsFont(.sm, weight: .semibold)
        Text(status).dsFont(.sm)
          .foregroundStyle(isFailure ? DS.Palette.warning : DS.Palette.textSecondary)
        Spacer(minLength: DS.Space.s2)
        Toggle(tr("跟随输出"), isOn: $followsOutput).toggleStyle(.checkbox).fixedSize()
      }
      if controller.outputWasTruncated {
        Text(tr("日志较长，仅保留最近 128 KiB。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          VStack(alignment: .leading, spacing: 0) {
            if let command = controller.lastCommand {
              Text(verbatim: "$ " + command.displayCommand)
                .foregroundStyle(DS.Palette.textSecondary)
            }
            if !controller.output.isEmpty { Text(verbatim: controller.output) }
            if let code = controller.exitStatus, code != 0 {
              Text(tr("退出码 \(code)")).foregroundStyle(DS.Palette.warning)
            }
            if let failure = controller.failure {
              Text(verbatim: failure).foregroundStyle(DS.Palette.warning)
            }
            Color.clear.frame(height: 1).id("end")
          }
          .font(.system(size: DS.TextSize.sm.rawValue, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(DS.Space.s3)
          // 内容高度独立于视口；短日志自然撑开，长日志受父布局剩余高度约束。
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            logContentHeight = $0
          }
        }
        .environment(\.layoutDirection, .leftToRight)
        // 窗口缩放或标题区域增高也会挤出末行，跟随时须重新对齐。
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: { _ in
          if followsOutput { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
        // 日志区按需挂载，快速命令可能在首次显示前已输出完毕。
        .onChange(of: controller.output, initial: true) { _, _ in
          if followsOutput { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
        .onChange(of: logContentHeight) { _, _ in
          if followsOutput { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
        .onChange(of: followsOutput) { _, follows in
          if follows { proxy.scrollTo("end", anchor: .bottomLeading) }
        }
      }
      .frame(minHeight: 0, idealHeight: logContentHeight, maxHeight: logContentHeight)
      .frame(maxWidth: .infinity)
      .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
  }

  private var isFailure: Bool {
    controller.failure != nil || (controller.exitStatus ?? 0) != 0
  }

  var status: String {
    let mole = controller
    if mole.isCancelling { return tr("正在停止…") }
    if mole.isRunning { return tr("执行中") }
    if mole.wasCancelled {
      if mole.lastCommand == .install { return tr("安装已停止") }
      if mole.lastCommand?.isPreview == true { return tr("预览已取消") }
      return mole.lastCommand == .clean
        ? tr("已停止，已清理部分不会恢复") : tr("已停止，已完成的优化不会撤销")
    }
    if isFailure || mole.exitStatus == nil {
      switch mole.lastCommand {
      case .scan, .optimizePreview: return tr("预览失败")
      case .clean: return tr("清理失败")
      case .optimize: return tr("优化失败")
      case .install: return tr("安装失败")
      case nil: return tr("命令未能启动")
      }
    }
    switch mole.lastCommand {
    case .scan, .optimizePreview: return tr("预览已完成")
    case .clean: return tr("清理命令已完成")
    case .optimize: return tr("优化命令已完成")
    case .install: return tr("安装已完成")
    case nil: return tr("命令未能启动")
    }
  }
}
