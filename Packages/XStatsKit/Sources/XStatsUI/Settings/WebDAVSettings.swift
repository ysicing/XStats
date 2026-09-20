import Localization
import SwiftUI

/// WebDAV 手动备份：编辑中的凭据与已保存配置分离，必须保存后才能发起请求。
struct WebDAVSettings: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var savedPassword = ""
    @State private var confirmingUpload = false
    @State private var operation: Task<Void, Never>?

    private var dirty: Bool {
        address != (model.sync.configuration?.directoryURL.absoluteString ?? "")
            || username != (model.sync.configuration?.username ?? "")
            || password != savedPassword
    }

    var body: some View {
        let sync = model.sync
        SettingsGroup(caption: "WebDAV") {
            GroupRow(showsDivider: false) {
                Text(tr("使用自己的 WebDAV 保存一份设置文件，仅手动上传和下载，不会自动合并。"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupRow {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    Text(tr("WebDAV 目录地址")).dsFont(.sm)
                    TextField("https://dav.example.com/XStats/", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(tr("WebDAV 目录地址"))
                    Text(tr("请填写已存在的 HTTPS 目录；文件名固定为 xstats-settings.json。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Text(tr("用户名")).dsFont(.sm)
                    TextField(tr("用户名"), text: $username).textFieldStyle(.roundedBorder)
                    Text(tr("密码或应用专用密码")).dsFont(.sm)
                    SecureField(tr("密码或应用专用密码"), text: $password).textFieldStyle(.roundedBorder)
                    HStack {
                        Text(tr("密码仅保存在这台 Mac 的钥匙串中"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        Button(tr("保存配置")) {
                            if sync.save(address: address, username: username, password: password) {
                                address = sync.configuration?.directoryURL.absoluteString ?? address
                                savedPassword = password
                            }
                        }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
            }
        }
        .disabled(sync.isBusy || sync.pendingDownload != nil)
        .onChange(of: address) { _, next in
            if next != sync.configuration?.directoryURL.absoluteString { password = "" }
        }
        .onChange(of: username) { _, next in
            if next != sync.configuration?.username { password = "" }
        }

        SettingsGroup(caption: tr("设置同步")) {
            GroupRow(showsDivider: false) {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    HStack {
                        Button(tr("上传本机设置")) { confirmingUpload = true }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .confirmationDialog(tr("覆盖远端设置？"), isPresented: $confirmingUpload, titleVisibility: .visible) {
                                Button(tr("上传并覆盖"), role: .destructive) { run { await sync.upload() } }
                                Button(tr("取消"), role: .cancel) {}
                            } message: {
                                Text(tr("远端文件将替换为当前设置；其他 Mac 的改动不会合并。"))
                            }
                        Button(tr("下载并应用")) { run { await sync.download() } }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                        Spacer()
                    }
                    .disabled(sync.isBusy || sync.configuration == nil || dirty || sync.pendingDownload != nil)
                    if dirty {
                        Text(tr("连接信息有改动，请先保存配置"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                    if sync.isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(sync.phase == .uploading ? tr("正在上传设置…") : tr("正在下载设置…")).dsFont(.sm)
                        }
                    }
                    if case .failed(let message) = sync.phase {
                        InfoBanner(icon: "exclamationmark.triangle", text: message, tone: .error)
                    } else if let message = sync.message {
                        InfoBanner(icon: "checkmark.circle", text: message)
                    }
                    if let date = sync.lastSyncedAt {
                        Text(tr("上次同步：\(date.formatted(.relative(presentation: .named).locale(L10n.locale)))"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            }
            if let backup = sync.pendingDownload {
                GroupRow {
                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        InfoBanner(icon: "arrow.down.circle", text: tr("应用远端设置？"), tone: .warning)
                        Text(tr("将应用 \(backup.savedAt.formatted(date: .abbreviated, time: .shortened)) 保存的设置，覆盖本机对应偏好。"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        HStack {
                            Spacer()
                            Button(tr("取消")) { sync.discardDownload() }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                            Button(tr("应用并覆盖")) { sync.confirmDownload() }
                                .buttonStyle(DSButtonStyle(kind: .primary))
                        }
                    }
                }
            }
            GroupRow {
                Text(tr("只同步偏好设置，不上传监控数据、历史记录或 WebDAV 连接信息。每台 Mac 需单独配置 WebDAV。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            address = sync.configuration?.directoryURL.absoluteString ?? ""
            username = sync.configuration?.username ?? ""
            password = sync.savedPassword()
            savedPassword = password
        }
        .onDisappear {
            operation?.cancel()
            sync.discardDownload()
            password = ""
            savedPassword = ""
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Task {
            await action()
            operation = nil
        }
    }
}
