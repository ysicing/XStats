<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**無料・オープンソースの macOS メニューバー用システムモニター。** CPU、メモリ、ネットワーク、温度をひと目で確認し、そのままクリーンアップ、ファン制御、スリープ防止もできます。

[![Release](https://img.shields.io/badge/version-0.14.3-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[ダウンロード](https://github.com/ysicing/xstats/releases) · [変更履歴（中国語）](CHANGELOG.md) · [開発ガイド（中国語）](DEVELOPMENT.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats のメニューバー表示">

</div>

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

## XStats を選ぶ理由

- **ひとつで何役も**：システム監視、ファン制御、スリープ防止、キャッシュのクリーンアップ、アプリのアンインストール、回線速度テスト、IP チェックをメニューバーからまとめて使えます。
- **ネイティブ・オープンソース・無料**：Swift と SwiftUI で開発。ソースは AGPL-3.0 で公開され、アカウントは不要です。
- **実行前に確認**：クリーンアップやアンインストールは対象を一覧表示し、確認してから実行します。先にゴミ箱へ移す設定もできます。
- **表示は自由に**：メニューバーの項目、並び順、表示スタイルを選べ、使わないモジュールはまるごとオフにできます。
- **9 つの表示言語**：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats ダッシュボード（ダーク）">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats ダッシュボード（ライト）">
</p>

## 主な機能

**システム監視**：CPU、GPU、メモリ、ディスク、ネットワーク、バッテリー、温度、ファンから表示する項目を選べます。項目を開くと履歴、使用量の多いアプリ、ハードウェアの詳細を確認できます。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="24%" alt="CPU の詳細">
  <img src="Assets/readme/popover-memory-dark.png" width="24%" alt="メモリの詳細">
  <img src="Assets/readme/popover-disk-light.png" width="24%" alt="ディスクの詳細">
  <img src="Assets/readme/ip-purity-light.png" width="24%" alt="IP クリーン度">
</p>

**システムツール**：ファン制御、スリープ防止（蓋を閉じた状態にも対応）、アプリのアンインストール、ログイン項目の管理。キャッシュとプロジェクト成果物のクリーンアップは、設定でオンにすると使えます。

**ネットワークツール**：接続、DNS、公開 IP を確認。必要なときに回線速度テスト、IP クリーン度と世界各地への接続性をチェックできます。

**オプションモジュール**（初期状態はオフ）：

- プロセス：全プロセスの表示、検索、並べ替え、アプリごとのグループ化、終了に対応します。
- メニューバーカレンダー：旧暦、中国の祝日と振替出勤日、暦注に加え、カレンダーの予定とリマインダーも表示します。
- ポモドーロと目の休憩：すべてのディスプレイに休憩画面を表示し、いつでもスキップ、一時停止、ミニ HUD への縮小ができます。
- AI 使用量：Codex / Claude Code のローカルのトークン使用量とサブスクリプション利用枠を確認します。

**デスクトップウィジェット**：システム概要、ポモドーロ、AI 利用枠、カレンダーと月表示、「明日は出勤？」、IP クリーン度、公開 IP。

## インストール

**Apple Silicon Mac と macOS 14 以降**が必要です。上の Homebrew コマンドでのインストールをおすすめします。更新は `brew upgrade --cask xstats` で行えます。

[GitHub Releases](https://github.com/ysicing/xstats/releases) から DMG をダウンロードするか、[ソースからビルド](DEVELOPMENT.md)することもできます。アプリ自身がアップデートを確認し、インストールするかどうかはユーザーが決められます。

## データとプライバシー

アカウントは不要です。次の機能は通信を行い、いずれも設定でオフにするか必要なときだけ使えます。

- **アップデートの確認**：バージョンとインストール ID のハッシュを送信します。
- **AI 使用量**（初期状態はオフ）：ローカルの Codex / Claude CLI のログインで利用枠を確認します。Sub2API を代替ソースとして設定できます。
- **公開 IP・速度テスト・接続テスト**：使用するときだけ各サービスに接続します。

詳細は[プライバシーポリシー（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md)と[利用規約（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md)を参照してください。

## ビルドと貢献

Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/)、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。主なコマンド：

```bash
task test
task build BUMP=0 INSTALL=0
```

Issue と Pull Request を歓迎します。環境構築とリリース手順は [DEVELOPMENT.md（中国語）](DEVELOPMENT.md)、構成は [ARCHITECTURE.md（英語）](ARCHITECTURE.md)を参照してください。

## 変更履歴

最新の変更は [CHANGELOG.md（中国語）](CHANGELOG.md)を参照してください。

## 謝辞とライセンス

XStats は [OpenStats](https://github.com/gentpan/OpenStats) を基に開発しています。元のプロジェクトと、[ThirdPartyNotices.md](ThirdPartyNotices.md) に記載した他のオープンソースプロジェクトに感謝します。XStats は Apple や本文に記載した企業とは独立した第三者アプリです。

XStats の新規コードと変更部分には **AGPL-3.0-or-later** を適用します。[LICENSE](LICENSE) と [LICENSING.md（中国語）](LICENSING.md)を参照してください。OpenStats の元のコードには [MIT ライセンス](LICENSES/OpenStats-MIT.txt)が引き続き適用されます。
