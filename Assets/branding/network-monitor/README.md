# XStats Network Monitor Logo

网络组件使用两条 Wi-Fi 信号弧线与缩小的 XStats 监控曲线，沿用蓝青渐变。

- `xstats-network-logo.svg`：透明矢量母版。
- `xstats-network-logo.png`：1024 × 1024 透明 PNG。
- `xstats-network-logo-{size}.png`：2048、512、256、128、64、32、16 像素的透明 PNG。

在仓库根目录运行 `bash scripts/render_network_icon.sh`（需 librsvg），重新生成透明品牌素材与
`Apps/NetworkMonitor/App/Assets.xcassets/AppIcon.appiconset` 的全部尺寸。

Dock／Finder 图标使用 `#FCFDFF` 近白纯色底，不绘制阴影、边框或金属质感；
圆角及系统效果由 macOS 管理。品牌素材始终透明，主程序图标使用独立资源。

SVG 及 PNG 导出采用 AGPL-3.0-or-later，见根目录的 `LICENSE` 和 `LICENSING.md`。
造型依据用户提供的参考重绘，未使用第三方图形或字体。
