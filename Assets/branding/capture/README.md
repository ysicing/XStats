# XStats Capture Logo

Capture 保留四角取景框和中央画面边框，在画面内嵌入 XStats 主曲线。曲线直接复用主标识的 2048 像素透明导出，保持相同轮廓与蓝青渐变。

- `xstats-capture-logo.png`：1024 × 1024 透明品牌标识。
- `xstats-capture-logo-{size}.png`：2048、512、256、128、64、32、16 像素的透明导出。
- `Apps/Capture/App/Assets.xcassets/AppIcon.appiconset`：近白 `#FCFDFF` 底色的应用图标，由系统管理圆角，无额外阴影或金属渐变。

在仓库根目录重新生成：

```sh
bash scripts/render_xstats_icon.sh
swift scripts/render_capture_icon.swift
```

品牌版的画面内部与图案外部均透明，不填充浅蓝玻璃底色。本目录资源及生成脚本采用 AGPL-3.0-or-later，见根目录的 `LICENSE` 和 `LICENSING.md`。
