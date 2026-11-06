# XStats Logo

XStats 的品牌标识采用独立的蓝青渐变监控曲线，背景透明，无容器、边框、阴影或光晕。

- `xstats-logo.svg`：矢量母版，单条闭合贝塞尔路径，适合网页、GitHub 和任意尺寸导出。
- `xstats-logo.png`：1024 × 1024 透明 PNG。
- `xstats-logo-{size}.png`：2048、512、256、128、64、32、16 像素的透明 PNG。

所有版本保持相同轮廓、比例和留白。PNG 曲线内部完全不透明，仅轮廓边缘包含抗锯齿过渡。请优先从 SVG 母版导出，避免反复缩放位图。

使用 librsvg（`brew install librsvg`）在仓库根目录重新生成全部尺寸，同时更新四语言 README 共用的 `Assets/icon.png`、应用内透明标识及主程序的 `AppIcon.appiconset`：

```sh
bash scripts/render_xstats_icon.sh
```

品牌 PNG、README 图片与应用内标识保留透明背景。关于页和更新页使用 `Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/xstats-logo.png`，直接读取资源包，避免跟随系统图标或实时 Dock 图标变化。

Dock／Finder 应用图标使用相同曲线和渐变，在完整画布上添加明亮的 `#FCFDFF` 纯色底，不绘制边框、阴影或金属渐变。完整底色避免系统将透明曲线作为独立前景缩小后放进灰色底板，曲线因此更饱满；圆角和系统效果由 macOS 管理。

网络组件使用 [独立的 Wi-Fi 与监控曲线标识](network-monitor/README.md)，由
`bash scripts/render_network_icon.sh` 生成透明品牌图片和近白底应用图标。
Capture 使用[取景框与主曲线组合标识](capture/README.md)，由
`swift scripts/render_capture_icon.swift` 生成透明品牌图片和近白底应用图标。
用户选择的实时动态图标模式沿用原有行为。

本目录的 SVG 及其 PNG 导出采用 AGPL-3.0-or-later，见根目录的 `LICENSE` 和 `LICENSING.md`。造型依据用户提供的参考图重绘，未使用第三方图形或字体。
