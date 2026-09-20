// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
    static let webDAVEnglish = #"""
请输入有效的 HTTPS WebDAV 目录地址，不要包含账号、查询参数或片段	Enter a valid HTTPS WebDAV directory URL without credentials, query parameters or fragments
请输入 WebDAV 用户名，不能包含冒号或控制字符	Enter a WebDAV username without colons or control characters
请输入 WebDAV 密码或应用专用密码	Enter your WebDAV password or app password
请先保存 WebDAV 配置	Save your WebDAV configuration first
WebDAV 认证失败，请检查用户名和密码	WebDAV authentication failed. Check your username and password
WebDAV 拒绝访问，请检查目录读写权限	WebDAV access denied. Check the directory's read and write permissions
远端尚无设置文件，请先上传本机设置	No remote settings file exists yet. Upload local settings first
WebDAV 目录不存在，请先在服务器上创建该目录	The WebDAV directory does not exist. Create it on the server first
远端文件已锁定，请稍后重试	The remote file is locked. Try again later
WebDAV 存储空间不足	WebDAV storage is full
WebDAV 地址发生重定向，请填写最终目录地址	The WebDAV address redirects. Enter the final directory URL
设置文件超过 1 MB，已停止同步	The settings file exceeds 1 MB. Sync stopped
远端文件不是有效的 XStats 设置备份，本机设置未更改	The remote file is not a valid XStats settings backup. Local settings are unchanged
设置备份版本不受支持，请先更新 XStats	This backup version is not supported. Update XStats first
无法连接 WebDAV，请检查网络、地址和 HTTPS 证书	Cannot connect to WebDAV. Check the network, URL and HTTPS certificate
WebDAV 返回错误：{}	WebDAV returned an error: {}
配置已保存，上传或下载时将验证连接	Configuration saved. The connection will be verified when uploading or downloading
本机设置已上传	Local settings uploaded
已应用远端设置	Remote settings applied
使用自己的 WebDAV 保存一份设置文件，仅手动上传和下载，不会自动合并。	Store a settings file on your own WebDAV server. Uploads and downloads are manual; changes are not merged automatically.
WebDAV 目录地址	WebDAV directory URL
请填写已存在的 HTTPS 目录；文件名固定为 xstats-settings.json。	Enter an existing HTTPS directory. The file is named xstats-settings.json.
用户名	Username
密码或应用专用密码	Password or app password
密码仅保存在这台 Mac 的钥匙串中	The password is stored only in this Mac's Keychain
保存配置	Save Configuration
设置同步	Settings Sync
覆盖远端设置？	Overwrite remote settings?
上传并覆盖	Upload and Overwrite
远端文件将替换为当前设置；其他 Mac 的改动不会合并。	The remote file will be replaced with these settings. Changes from other Macs will not be merged.
下载并应用	Download and Apply
连接信息有改动，请先保存配置	Connection details have changed. Save the configuration first
正在上传设置…	Uploading settings…
正在下载设置…	Downloading settings…
只同步偏好设置，不上传监控数据、历史记录或 WebDAV 连接信息。每台 Mac 需单独配置 WebDAV。	Only preferences are synced. Monitoring data, history and WebDAV connection details are excluded. Configure WebDAV separately on each Mac.
应用远端设置？	Apply remote settings?
应用并覆盖	Apply and Overwrite
将应用 {} 保存的设置，覆盖本机对应偏好。	Apply settings saved at {}, overwriting the corresponding local preferences.
"""#
}
