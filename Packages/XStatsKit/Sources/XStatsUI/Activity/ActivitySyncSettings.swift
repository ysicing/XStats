// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI
import UniformTypeIdentifiers
import WebDAVSync

struct ActivitySyncSettings: View {
  let controller: ActivitySyncController
  @Environment(\.dismiss) private var dismiss
  @State private var provider: ActivitySyncProvider
  @State private var address: String
  @State private var username: String
  @State private var secret = ""
  @State private var folder: URL?
  @State private var pickingFolder = false
  @State private var failure: String?
  @State private var recoveryAction: RecoveryAction?

  init(controller: ActivitySyncController) {
    self.controller = controller
    _provider = State(initialValue: controller.provider)
    _address = State(initialValue: controller.address)
    _username = State(initialValue: controller.username)
  }

  private var dirty: Bool {
    provider != controller.provider
      || (provider == .webDAV
        && (address != controller.address || username != controller.username || !secret.isEmpty))
      || (provider == .googleDrive && folder != nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(tr("存储位置")).font(.headline)
      Form {
        Picker(tr("存储位置"), selection: $provider) {
          ForEach(ActivitySyncProvider.allCases, id: \.self) { destination in
            Text(verbatim: destination.settingsTitle).tag(destination)
          }
        }
        .pickerStyle(.radioGroup)
        if provider == .webDAV {
          TextField(tr("WebDAV 目录地址"), text: $address)
          TextField(tr("用户名"), text: $username)
          SecureField(tr("密码或应用专用密码"), text: $secret)
          Text(tr("密码仅保存在这台 Mac 的钥匙串中")).font(.caption).foregroundStyle(.secondary)
          if URLComponents(string: address)?.scheme?.lowercased() == "http" {
            Text(tr("HTTP 仅限内网或 Tailscale，WebDAV 登录凭据会通过 HTTP 发送。"))
              .font(.caption).foregroundStyle(.secondary)
          }
        } else if provider == .googleDrive {
          LabeledContent(tr("共享文件夹")) {
            if let name = folder?.lastPathComponent
              ?? (controller.folderName.isEmpty ? nil : controller.folderName)
            {
              Text(verbatim: name).lineLimit(1).truncationMode(.middle)
            }
            Button(tr("选择文件夹")) { pickingFolder = true }
          }
          Text(tr("使用 Google Drive 桌面版同步的文件夹。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup(tr("同步恢复密钥")) {
          HStack {
            Button(tr("查看恢复密钥")) { recoveryAction = .show }
            Button(tr("导入恢复密钥")) { recoveryAction = .enter }
          }
        }
      }
      if let failure {
        Text(verbatim: failure).font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button(tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(tr("保存配置")) {
          do {
            try controller.save(
              provider: provider, address: address, username: username, secret: secret,
              folder: folder)
            secret = ""
            dismiss()
          } catch {
            failure =
              (error as? ActivityDAVError)?.errorDescription
              ?? (error as? WebDAVError)?.errorDescription ?? tr("无法保存同步配置")
          }
        }
        .disabled(!dirty)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 400)
    .sheet(item: $recoveryAction) { action in
      ActivityRecoverySheet(controller: controller, action: action)
    }
    .onChange(of: address) { _, _ in secret = "" }
    .onChange(of: username) { _, _ in secret = "" }
    .onChange(of: provider) { _, _ in
      secret = ""
      failure = nil
    }
    .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url): folder = url
      case .failure(let error):
        if (error as NSError).code != NSUserCancelledError { failure = tr("无法打开共享文件夹") }
      }
    }
  }
}

private enum RecoveryAction: String, Identifiable {
  case show, enter
  var id: Self { self }
}

private struct ActivityRecoverySheet: View {
  let controller: ActivitySyncController
  let action: RecoveryAction
  @Environment(\.dismiss) private var dismiss
  @State private var code = ""
  @State private var failure: String?
  @State private var confirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(tr("同步恢复密钥")).font(.headline)
      Text(tr("在其他 Mac 导入同一密钥，即可读取加密的活动记录。请妥善保存。"))
        .foregroundStyle(.secondary)
      if action == .show {
        Text(verbatim: code).font(.body.monospaced()).textSelection(.enabled)
          .privacySensitive()
      } else {
        SecureField(tr("同步恢复密钥"), text: $code)
      }
      if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button(tr("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
        if action == .enter {
          Button(tr("导入恢复密钥")) {
            Task { await importCode() }
          }
          .disabled(code.isEmpty || controller.changingKey)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(idealWidth: 460)
    .task {
      if action == .show {
        do { code = try await controller.recoveryCode() } catch {
          failure = tr("无法读取或保存活动密钥，请检查钥匙串")
        }
      }
    }
    .alert(tr("替换这台 Mac 的同步密钥？"), isPresented: $confirm) {
      Button(tr("取消"), role: .cancel) {}
      Button(tr("替换密钥"), role: .destructive) {
        Task { await importCode(confirmExisting: true) }
      }
    } message: {
      Text(tr("请先保存原恢复密钥，以便日后读取使用原密钥加密的云端记录。"))
    }
  }

  private func importCode(confirmExisting: Bool = false) async {
    do {
      try await controller.importRecoveryCode(code, confirmExisting: confirmExisting)
      dismiss()
    } catch ActivityKeys.Failure.replacementRequired {
      failure = nil
      confirm = true
    } catch ActivityKeys.Failure.invalidRecoveryCode {
      failure = tr("恢复密钥格式无效")
    } catch {
      failure = tr("无法读取或保存活动密钥，请检查钥匙串")
    }
  }
}
