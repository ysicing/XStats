// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Metrics
import Localization
import SwiftUI

extension AudioListeningMode {
  var title: String {
    switch self {
    case .off: tr("关闭")
    case .noiseCancellation: tr("降噪")
    case .transparency: tr("通透")
    case .adaptive: tr("自适应")
    }
  }
}

/// 控件即时跟随输入；异步状态只作明确反馈，不移动正在操作的内容。
struct AudioMixerContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isPopover) private var isPopover

  var body: some View {
    if isPopover {
      AudioDeviceSection(direction: .output)
      AudioDeviceSection(direction: .input)
    } else {
      HStack(alignment: .top, spacing: DS.Space.s3) {
        AudioDeviceSection(direction: .output).frame(maxWidth: .infinity)
        AudioDeviceSection(direction: .input).frame(maxWidth: .infinity)
      }
    }
    SectionCard(
      title: tr("应用音量"), hint: tr("应用音量支持 0–200%；高增益时自动限制峰值，不改变系统音量。"),
      trailing: {
        Toggle(
          tr("应用音量"),
          isOn: Binding(
            get: { model.audio.appVolumeEnabled || model.audio.isAuthorizing },
            set: { enabled in
              if enabled { model.audio.authorizeMixing() } else { model.audio.disableMixing() }
            })
        )
        .toggleStyle(.switch).controlSize(.small).labelsHidden()
        .disabled(
          !model.audio.supportsMixing || (model.audio.isWorking && !model.audio.isAuthorizing)
        )
        .accessibilityIdentifier("audio.appVolumeEnabled")
      }
    ) {
      if !model.audio.supportsMixing {
        Text(tr("应用音量需要 macOS 14.4 或更新版本")).dsFont(.sm)
      } else if !model.audio.appVolumeEnabled {
        Text(tr("开启后可独立调节正在播放声音的应用。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).fixedSize(
            horizontal: false, vertical: true)
        if model.audio.isAuthorizing { AudioSwitchingFeedback(text: tr("正在请求音频权限…")) }
      } else if model.audio.listedApplications.isEmpty {
        Text(tr("暂无正在播放或已调整音量的应用")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
      } else {
        ForEach(model.audio.listedApplications) { app in AudioApplicationRow(app: app) }
      }
    }
    if let error = model.audio.error {
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Label(errorMessage(error), systemImage: "exclamationmark.triangle")
          .dsFont(.sm).foregroundStyle(DS.Palette.error).fixedSize(
            horizontal: false, vertical: true)
        if model.audio.canRetryMixing {
          Button(tr("重试应用音频")) { model.audio.retryMixing() }.buttonStyle(.bordered).disabled(
            model.audio.isWorking)
        }
      }
    }
  }
  private func errorMessage(_ error: AudioControlError) -> String {
    switch error {
    case .permissionRequired: tr("请在系统设置的屏幕与系统音频录制中允许 XStats，然后重新开启应用音量。")
    case .renderStalled: tr("应用音频未恢复，已停止自动重试。")
    case .processingLimit(let limit): tr("最多同时处理 \(limit) 个应用，请恢复部分应用的原始音量或默认输出。")
    case .routeChanged: tr("音频设备已变化，请重试。")
    case .unsupportedFormat: tr("当前输出格式不支持应用音量，请切换音频设备。")
    case .unsupported: tr("此设备不支持该控制。")
    case .bluetoothUnavailable: tr("蓝牙未开启，请在系统设置中开启蓝牙。")
    case .bluetoothPermissionRequired: tr("请在系统设置的隐私与安全性中允许 XStats 使用蓝牙。")
    case .bluetoothConnectionFailed: tr("无法连接蓝牙设备，请确认设备已开启且在附近，然后重试。")
    case .bluetoothAudioUnavailable: tr("蓝牙音频未就绪，请确认设备支持所选的输入或输出，然后重试。")
    case .bluetoothDisconnectionFailed: tr("蓝牙设备未断开，请重试。")
    case .listeningModeUnconfirmed: tr("聆听模式切换未确认，请检查耳机后重试。")
    case .unavailable, .hardware: tr("音频操作未完成，请重试。")
    }
  }
}

private struct AudioSwitchingFeedback: View {
  let text: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: DS.Space.s1) {
      if reduceMotion {
        Image(systemName: "hourglass").accessibilityHidden(true)
      } else {
        ProgressView().controlSize(.mini).accessibilityHidden(true)
      }
      Text(text).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    }
  }
}

struct AudioListeningModeControl: View {
  let state: AudioListeningModeState
  let target: AudioListeningMode?
  let busy: Bool
  let select: @MainActor @Sendable (AudioListeningMode) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(tr("聆听模式")).dsFont(.sm)
      ViewThatFits(in: .horizontal) {
        buttons(horizontal: true)
        buttons(horizontal: false)
      }
      if let target {
        AudioSwitchingFeedback(text: tr("正在切换到“\(target.title)”…"))
      }
    }
  }

  private func buttons(horizontal: Bool) -> some View {
    let layout =
      horizontal
      ? AnyLayout(HStackLayout(spacing: DS.Space.s1))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s1))
    return layout {
      ForEach(state.modes, id: \.rawValue) { @Sendable [state, busy, select] mode in
        AudioListeningModeButton(
          mode: mode, selected: state.current == mode, busy: busy, select: select)
      }
    }
  }
}

private struct AudioListeningModeButton: View {
  let mode: AudioListeningMode
  let selected: Bool
  let busy: Bool
  let select: @MainActor @Sendable (AudioListeningMode) -> Void

  nonisolated init(
    mode: AudioListeningMode, selected: Bool, busy: Bool,
    select: @escaping @MainActor @Sendable (AudioListeningMode) -> Void
  ) {
    self.mode = mode
    self.selected = selected
    self.busy = busy
    self.select = select
  }

  var body: some View {
    Button {
      select(mode)
    } label: {
      Label(mode.title, systemImage: selected ? "checkmark.circle.fill" : "circle").fixedSize()
    }
    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct AudioDeviceSection: View {
  let direction: AudioDirection
  @Environment(AppModel.self) private var model
  @State private var draft = AudioDeviceVolumeDraft()
  @State private var finishTask: Task<Void, Never>?
  private var device: AudioDeviceInfo? {
    direction == .output ? model.audio.output : model.audio.input
  }
  private var title: String { direction == .output ? tr("输出设备") : tr("输入设备") }
  private var volumeTitle: String { direction == .output ? tr("系统音量") : tr("输入音量") }
  private var level: Double? { direction == .output ? device?.outputVolume : device?.inputVolume }
  private var muted: Bool {
    (direction == .output ? device?.outputMuted : device?.inputMuted) == true
  }
  private var canSetVolume: Bool {
    (direction == .output ? device?.canSetOutputVolume : device?.canSetInputVolume) == true
  }
  private var canSetMute: Bool {
    (direction == .output ? device?.canSetOutputMute : device?.canSetInputMute) == true
  }
  private var muteLabel: String {
    if direction == .input { return muted ? tr("取消麦克风静音") : tr("静音麦克风") }
    return muted ? tr("取消输出静音") : tr("静音输出")
  }
  var body: some View {
    SectionCard(title: title) {
      let preferences = model.settings.bluetoothDevicePreferences
      let selectedAddress = device?.bluetoothAddress.flatMap(BluetoothDevicePreferences.key)
      let keeping = Set([selectedAddress, model.audio.connectingBluetooth].compactMap { $0 })
      let devices = preferences.arranged(
        model.audio.snapshot.devices.filter { $0.canBeDefault(direction) },
        address: { $0.bluetoothAddress ?? "" }, keeping: keeping)
      let paired = preferences.arranged(
        model.audio.bluetoothDevices, address: \.address, keeping: keeping
      ).filter { candidate in
        guard direction == .output ? candidate.hasOutput : candidate.hasInput else { return false }
        // HAL 端点先出现、切换稍后完成；保留待处理选项，避免 Picker 的 selection 暂时失去标签。
        if model.audio.switchingDevice == direction, model.audio.connectingBluetooth == candidate.id
        {
          return true
        }
        return !model.audio.snapshot.devices.contains(where: {
          candidate.matches($0, direction: direction)
        })
      }
      if !devices.isEmpty || !paired.isEmpty {
        Picker(
          title,
          selection: Binding(
            get: {
              if model.audio.switchingDevice == direction, let id = model.audio.connectingBluetooth
              {
                return "bluetooth:\(id)"
              }
              return device.map { "audio:\($0.id)" } ?? ""
            },
            set: { selection in
              if selection.hasPrefix("bluetooth:") {
                model.audio.connectBluetooth(String(selection.dropFirst(10)), direction: direction)
              } else if let id = UInt32(selection.dropFirst(6)) {
                model.audio.selectDevice(id, direction: direction)
              }
            })
        ) {
          if device == nil { Text(title).tag("") }
          ForEach(devices) { Text(verbatim: $0.name).tag("audio:\($0.id)") }
          if !paired.isEmpty {
            Divider()
            ForEach(paired) { candidate in
              if model.audio.switchingDevice == direction,
                model.audio.connectingBluetooth == candidate.id
              {
                Text(verbatim: candidate.name).tag("bluetooth:\(candidate.id)")
              } else {
                Text(tr("\(candidate.name) · 未连接")).tag("bluetooth:\(candidate.id)")
              }
            }
          }
        }.labelsHidden().pickerStyle(.menu).disabled(model.audio.isWorking)
        if direction == .output {
          if let id = model.audio.disconnectingBluetooth,
            let paired = model.audio.bluetoothDevices.first(where: { $0.id == id })
          {
            AudioSwitchingFeedback(text: tr("正在断开“\(paired.name)”…"))
          } else if model.audio.connectedBluetoothOutput != nil {
            Button(tr("断开连接")) { model.audio.disconnectBluetoothOutput() }
              .buttonStyle(DSButtonStyle(kind: .secondary)).disabled(model.audio.isWorking)
              .help(tr("断开此蓝牙音频设备的输入与输出连接"))
              .accessibilityIdentifier("audio.disconnectBluetoothOutput")
          }
          if let state = model.audio.listeningMode, state.isControllable {
            AudioListeningModeControl(
              state: state, target: model.audio.changingListeningMode, busy: model.audio.isWorking,
              select: { model.audio.setListeningMode($0) })
          }
        }
        if model.audio.switchingDevice == direction {
          if let id = model.audio.connectingBluetooth,
            let paired = model.audio.bluetoothDevices.first(where: { $0.id == id })
          {
            AudioSwitchingFeedback(text: tr("正在连接“\(paired.name)”…"))
          } else {
            AudioSwitchingFeedback(text: tr("正在切换设备…"))
          }
        }
        if device != nil {
          HStack(spacing: DS.Space.s2) {
            Image(
              systemName: direction == .output
                ? AudioControlPresentation.outputSymbol(device) : "mic"
            )
            .foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
            Text(volumeTitle).dsFont(.sm)
            Spacer(minLength: DS.Space.s1)
            if let level {
              Text(
                verbatim: (draft.value ?? level).formatted(
                  .percent.precision(.fractionLength(0)).locale(L10n.locale))
              )
              .dsFont(.sm, weight: .medium).monospacedDigit().accessibilityHidden(canSetVolume)
              .accessibilityLabel(volumeTitle)
              .accessibilityValue(
                (draft.value ?? level).formatted(
                  .percent.precision(.fractionLength(0)).locale(L10n.locale)))
            }
            if canSetMute {
              MiniIconButton(
                systemName: AudioControlPresentation.muteSymbol(direction, muted: muted),
                help: muteLabel
              ) {
                model.audio.toggleDeviceMute(direction)
              }.disabled(model.audio.isWorking)
            }
          }
          if muted { Text(tr("已静音")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
          if let level, canSetVolume {
            Slider(
              value: Binding(
                get: { draft.value ?? level },
                set: {
                  draft.update($0)
                  model.audio.setDeviceLevel($0, direction: direction)
                }),
              in: 0...1, onEditingChanged: editingChanged
            )
            .controlSize(.small).tint(muted ? DS.Palette.textSecondary : DS.Palette.primary)
            .disabled(model.audio.isWorking).accessibilityLabel(volumeTitle)
            .help(tr("在滑杆上向上滚动调高音量，向下滚动调低音量"))
            .overlay {
              AudioVolumeScroll(enabled: !model.audio.isWorking) { delta in
                let current = draft.value ?? level
                let next = min(1, max(0, current + delta))
                guard next != current else { return }
                editingChanged(true)
                draft.update(next)
                model.audio.setDeviceLevel(next, direction: direction)
                editingChanged(false)
              }
            }
            .accessibilityValue(
              (draft.value ?? level).formatted(
                .percent.precision(.fractionLength(0)).locale(L10n.locale)))
          } else {
            Text(tr("此设备的音量由设备自身控制")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          }
        }
        if direction == .output,
          let battery = AudioControlPresentation.connectedBattery(
            for: device, devices: model.bluetooth.devices)
        {
          BluetoothDeviceList(devices: [battery])
        }
      } else {
        Text(tr("没有可用音频设备")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
      }
    }
    .onChange(of: level) { _, _ in draft.readbackChanged() }
    .onChange(of: device?.uid) { _, _ in resetDraft() }
    .onChange(of: model.audio.error) { _, error in if error != nil { resetDraft() } }
    .onDisappear { resetDraft() }
  }

  private func editingChanged(_ editing: Bool) {
    finishTask?.cancel()
    finishTask = nil
    if editing {
      draft.beginEditing()
      return
    }
    let token = draft.endEditing()
    finishTask = Task { @MainActor in
      await model.audio.finishDeviceVolumeEditing()
      guard !Task.isCancelled, draft.complete(token) else { return }
      finishTask = nil
    }
  }

  private func resetDraft() {
    finishTask?.cancel()
    finishTask = nil
    draft.reset()
  }
}

struct AudioApplicationRow: View {
  let app: AudioApplication
  @Environment(AppModel.self) private var model
  @State private var icon: NSImage?
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.isPopover) private var isPopover

  var body: some View {
    let volume = model.audio.volume(for: app)
    let resettable = volume.needsProcessing || model.audio.outputRoutes[app.id] != nil
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      HStack(spacing: DS.Space.s2) {
        Group {
          if isSnapshot, let url = app.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
          } else if let icon {
            Image(nsImage: icon).resizable()
          } else {
            Image(systemName: "app.fill").resizable().foregroundStyle(DS.Palette.textSecondary)
          }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: app.name).dsFont(.sm, weight: .medium).lineLimit(1).help(app.name)
          // 状态共用同一行：播放、暂停及报错切换时不移动正在操作的滑块。
          Group {
            if model.audio.unresolvedApps.contains(app.id) {
              Text(tr("音量或输出控制未生效。")).foregroundStyle(DS.Palette.error)
                .help(tr("音量或输出控制未生效。"))
            } else if app.isPlaying && model.audio.pendingOutputApps.contains(app.id) {
              AudioSwitchingFeedback(text: tr("正在切换输出…"))
            } else if model.audio.failedOutputApps.contains(app.id) {
              Text(tr("输出切换未完成，请重试。")).foregroundStyle(DS.Palette.error)
                .help(tr("输出切换未完成，请重试。"))
            } else {
              HStack(spacing: DS.Space.s1) {
                if volume.isMuted { Text(tr("已静音")) } else if !app.isPlaying { Text(tr("当前未播放")) }
                if let uid = model.audio.outputRoutes[app.id] {
                  if volume.isMuted || !app.isPlaying { Text("·") }
                  let outputName =
                    model.audio.snapshot.devices.first { $0.uid == uid && $0.hasOutput }?.name
                    ?? tr("设备不可用，使用系统默认")
                  Text(verbatim: outputName).help(outputName)
                } else if app.isPlaying && !volume.isMuted {
                  Text(tr("系统默认输出"))
                }
              }.foregroundStyle(DS.Palette.textSecondary)
            }
          }.dsFont(.xs).lineLimit(1).frame(height: DS.Size.iconInline, alignment: .leading)
        }
        Spacer(minLength: DS.Space.s1)
        Text(
          verbatim: volume.level.formatted(
            .percent.precision(.fractionLength(0)).locale(L10n.locale))
        )
        .dsFont(.sm, weight: .medium).monospacedDigit()
        .foregroundStyle(
          volume.isMuted
            ? DS.Palette.textSecondary
            : volume.level > 1 ? DS.Palette.warning : DS.Palette.textPrimary
        )
        .fixedSize().accessibilityHidden(true)
        MiniIconButton(
          systemName: volume.isMuted ? "speaker.slash" : "speaker.wave.2",
          help: volume.isMuted ? tr("取消“\(app.name)”静音") : tr("静音“\(app.name)”")
        ) { model.audio.toggleAppMute(app) }
        Menu {
          Picker(
            tr("\(app.name) 输出设备"),
            selection: Binding(
              get: { model.audio.outputRoutes[app.id] ?? "" },
              set: {
                model.audio.setAppOutput($0.isEmpty ? nil : $0, app: app)
              })
          ) {
            Text(tr("系统默认输出")).tag("")
            if let selected = model.audio.outputRoutes[app.id],
              !model.audio.snapshot.devices.contains(where: { $0.uid == selected && $0.hasOutput })
            {
              Text(tr("设备不可用，使用系统默认")).tag(selected)
            }
            ForEach(model.audio.snapshot.devices.filter(\.hasOutput)) {
              Text(verbatim: $0.name).tag($0.uid)
            }
          }
          Divider()
          Button(tr("恢复“\(app.name)”的原始音量与默认输出"), systemImage: "arrow.counterclockwise") {
            model.audio.resetApp(app)
          }.disabled(!resettable)
        } label: {
          Label(tr("\(app.name) 音频选项"), systemImage: "ellipsis")
            .labelStyle(.iconOnly).dsFont(.xs)
            .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(tr("\(app.name) 音频选项"))
      }
      Slider(
        value: Binding(get: { volume.level }, set: { model.audio.setAppLevel($0, app: app) }),
        in: 0...2
      )
      .controlSize(.small).tint(
        volume.isMuted
          ? DS.Palette.textSecondary : volume.level > 1 ? DS.Palette.warning : DS.Palette.primary
      )
      .accessibilityLabel(tr("\(app.name) 音量"))
      .accessibilityValue(
        volume.level.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
      )
      .help(tr("应用音量支持 0–200%；高增益时自动限制峰值，不改变系统音量。"))
    }
    .padding(.vertical, isPopover ? DS.Space.s1 : DS.Space.s2).disabled(model.audio.isWorking)
    .task(id: app.bundleURL) {
      // 系统图标只在连接身份变化时加载，避免 Slider 热路径反复读文件。
      icon = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
  }
}

enum AudioControlPresentation {
  static func outputSymbol(_ device: AudioDeviceInfo?, muted: Bool = false) -> String {
    if muted { return "speaker.slash" }
    switch device?.outputKind ?? .unknown {
    case .headphones: return "headphones"
    case .bluetooth: return "dot.radiowaves.left.and.right"
    case .usb: return "cable.connector"
    case .display: return "display"
    case .speaker, .unknown: return "speaker.wave.2"
    }
  }

  static func connectedBattery(for output: AudioDeviceInfo?, devices: [BluetoothDevice]?)
    -> BluetoothDevice?
  {
    guard let output, output.hasOutput else { return nil }
    return devices?.first {
      $0.isConnected && !$0.batteries.isEmpty && output.matchesBluetoothAddress($0.address)
    }
  }

  static func muteSymbol(_ direction: AudioDirection, muted: Bool) -> String {
    direction == .input
      ? (muted ? "mic.slash" : "mic") : (muted ? "speaker.slash" : "speaker.wave.2")
  }
}
