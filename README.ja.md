<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

macOS 向けのオープンソースのメニューバー監視・メンテナンスアプリです。

[![Release](https://img.shields.io/badge/version-0.9.1-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[ダウンロード](https://github.com/ysicing/xstats/releases) · [変更履歴（中国語）](CHANGELOG.md) · [開発ガイド（中国語）](DEVELOPMENT.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

</div>

XStats は CPU、GPU、メモリ、ディスク、ネットワーク、バッテリー、温度、ファンの状態をメニューバーに表示します。項目を開くと履歴や詳細を確認でき、ファン制御、スリープ防止、キャッシュ削除、アプリのアンインストールも行えます。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="ダークモードの XStats ダッシュボード">
  <img src="Assets/readme/overview-light.png" width="49%" alt="ライトモードの XStats ダッシュボード">
</p>

## 主な機能

- **システム監視**：メニューバーの項目と表示形式を選び、ポップオーバーやメイン画面で推移、プロセス、ハードウェア情報を確認できます。
- **システムツール**：ファン制御、スリープ防止、キャッシュ削除、アプリの削除、起動項目の管理。削除前には内容を確認できます。
- **ネットワークツール**：接続、DNS、公開 IP を確認し、必要に応じて IP 評価や疎通を調べます。
- **任意の機能**：独立したメニューバーカレンダー、Codex / Claude Code のローカルセッションの Token 統計とサブスクリプション利用枠の照会。
- **デスクトップウィジェット**：システム概要、AI 利用枠、カレンダー、IP の信頼度、公開 IP。AI と IP のデータはメインアプリのローカルキャッシュから読み取ります。

## インストール

[GitHub Releases](https://github.com/ysicing/xstats/releases) からダウンロードしてください。**Apple Silicon Mac と macOS 14 以降**が必要です。[ソースからのビルド](DEVELOPMENT.md)も可能です。

画面は簡体字・繁体字中国語、英語、日本語、韓国語、ドイツ語、スペイン語、フランス語、アラビア語に対応します。更新が見つかっても、インストールするかどうかはユーザーが選べます。

## データとプライバシー

システムの監視データは Mac 内に保存され、XStats アカウントは不要です。AI の使用量と利用枠は初期状態では無効です。有効にすると、ローカル統計はセッションログを読み、利用枠の照会は対応する CLI のログイン情報を変更せずに読み取って各サービスへ直接問い合わせます。自分の Sub2API サーバーを代替の利用枠ソースとして設定できます。

公開 IP の照会と接続テストは、その機能を使用するときだけ通信します。更新確認ではバージョンとランダムなインストール ID の SHA-256 を送信し、サーバーはリクエスト IP を永続保存しません。WebDAV 同期はユーザーが設定したサーバーで手動実行し、設定のみを転送します。監視履歴や認証情報は転送しません。

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
