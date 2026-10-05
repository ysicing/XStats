<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**システムの状態と日常のツールを、Mac のメニューバーに。**

CPU、メモリ、ネットワーク、温度をひと目で確認し、詳細を開いて推移やアプリの使用状況を見られます。
AI 使用量、カレンダー、ファン制御、クリーンアップは必要なときに有効にできます。

[![Release](https://img.shields.io/badge/version-0.14.5-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[最新版をダウンロード](https://github.com/ysicing/xstats/releases) · [スクリーンショット](#スクリーンショット) · [主な機能](#主な機能) · [インストール](#インストール) · [変更履歴（中国語）](CHANGELOG.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats のメニューバー表示">

</div>

## スクリーンショット

メインウィンドウでシステムの状態をまとめて確認できます。ライトとダークの外観は好みに合わせて選べます。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats ダッシュボード（ダーク）">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats ダッシュボード（ライト）">
</p>

## 主な機能

XStats は Swift、AppKit、SwiftUI で開発した、無料のオープンソースのネイティブアプリです。XStats 用のアカウント登録は不要で、表示する項目や使うツールを選べます。

### メニューバーの表示を選ぶ

- **個別表示**：よく確認する指標ごとにメニューバーの項目を表示します。
- **まとめて表示**：複数の値をひとつにまとめ、開くと状態の概要を確認できます。
- **アイコンのみ**：XStats のアイコンだけを表示し、開くと選択した項目を確認できます。

表示する項目、並び順、スタイルを変更できます。指標に応じて文字、アイコン、リング、進捗バー、履歴グラフを選べ、不要な項目はオフにできます。

### システム監視と詳しい情報

| モジュール | 確認できる情報 |
|---|---|
| **CPU** | ユーザー / システム / アイドルの使用率、コアごとの負荷リング、コアグループの使用率、平均負荷、取得可能な周波数と温度。macOS の熱負荷が高いときは警告を表示 |
| **GPU** | グラフィックスの使用率、コア数などのハードウェア情報、取得可能な温度と消費電力 |
| **メモリ** | メモリプレッシャー、アプリと圧縮メモリ、キャッシュ、スワップ容量、スワップイン / アウトの速度 |
| **ディスク** | 容量、読み書きの速度、アプリ別 I/O ランキング、取得可能な SMART 健全性情報 |
| **ネットワーク** | アップロード / ダウンロードの速度、ネットワークインターフェイス、接続の概要 |
| **バッテリーと Bluetooth** | バッテリー残量、電源、健全性、充放電回数。対応する Bluetooth 機器の残量は、バッテリーのない Mac でもメニューバーに表示可能 |
| **温度とファン** | 温度センサーのグループ、ファン回転数、取得可能な消費電力 |
| **ディスプレイ** | モデル、解像度、スケーリング解像度、リフレッシュレート。対応する外部ディスプレイの明るさ、コントラスト、音量の調節 |

コアの種類はシステムが報告する情報に従います。スーパー / パフォーマンス / 高効率コアを実際の構成でグループ化し、機種名から 2 種類や 3 種類に固定しません。「この Mac」ではモデル、OS バージョン、稼働時間も確認できます。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU の使用率とコアの詳細">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="メモリ構成とプレッシャー">
</p>

**外部ディスプレイの制御**には、ディスプレイ、ケーブル、接続方式の DDC/CI 対応が必要です。各項目を個別に検出し、非対応や一時的に読み取れない場合は状態を表示します。対応する項目にだけスライダーを表示します。

### AI 使用量とサブスクリプション利用枠

メニューバーで Codex / Claude Code の使用量を確認し、開くと統計と利用枠の詳細を見られます。

- **トークン統計**：今日は時間ごと、直近 7 日 / 30 日は日ごとに表示。メインウィンドウには年間のアクティビティヒートマップもあります。
- **サブスクリプション利用枠**：使用済み / 残りの割合を切り替え、リセット時刻や、取得元が提供するプラン、有効期限、残りのリセット回数などを確認できます。
- **推定費用**：公開されているモデルの API 基本単価から算出し、米ドル / 人民元表示に対応。段階制料金は含まず、サブスクリプションの請求額を示すものではありません。
- **表示設定**：更新間隔と、中国語の万 / 亿または K / M / B の数値単位を選べます。

AI 使用量は初期状態でオフです。ローカル統計には Codex / Claude Code のセッションログを読み込み、利用枠の照会には対応する CLI へのログインが必要です。Sub2API を代替ソースとして設定することもできます。

### 必要なときに使う日常のツール

- **ファン制御**：動作状態を確認し、対応する機器で自動 / 手動制御を切り替えます。
- **スリープ防止**：システムや画面を起動状態に保ち、設定すれば蓋を閉じた状態での動作にも対応します。
- **クリーンアップとアンインストール**：キャッシュ、プロジェクト成果物、アプリ関連ファイルを削除。実行前に対象を確認し、ゴミ箱へ移すこともできます。
- **起動項目の管理**：ログイン項目とバックグラウンドの起動項目を確認・管理します。
- **ネットワーク診断**：必要なときに速度テスト、DNS 照会、外部への接続経路の確認、公開 IP の所在地とクリーン度、接続テストを実行します。
- **メニューバーカレンダー**：旧暦、中国の祝日と振替出勤日、暦注を表示。許可を与えるとカレンダーの予定とリマインダーも確認できます。
- **オーディオ**：初期状態では無効。システム音量、ミュート、出力・入力機器の切り替えに対応。ペアリング済みの Bluetooth オーディオ機器を選択すると接続を試み、音声の準備ができてから切り替えます。macOS 14.4 以降では許可後に再生中のアプリの音量（0〜200%）、ミュート、個別の出力先、リセットを調節できます。音声は本機で処理し、録音やアップロードは行いません。機器が音量調節に非対応の場合は説明を表示します。
- **ポモドーロと目の休憩**：集中と休憩のタイマー、複数画面の休憩表示に対応し、一時停止、スキップ、ミニ HUD への縮小ができます。
- **プロセス管理**：有効にすると全プロセスの表示、検索、並べ替え、アプリ別のグループ化、終了に対応します。

クリーンアップ、プロセス、カレンダー、ポモドーロ、AI 使用量は初期状態でオフです。必要なものだけ有効にできます。ファン制御や蓋を閉じた状態のスリープ防止など、特権が必要な操作には、アプリ内から補助ツールをインストールして許可を与える必要があります。

<details>
<summary>その他のツールのスクリーンショット</summary>

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="温度とファン制御">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="スリープ防止の設定">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="クリーンアップのプレビュー">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="公開 IP とクリーン度の確認">
</p>

</details>

### デスクトップウィジェットと表示言語

ウィジェットにはシステム概要、ポモドーロ、AI 利用枠、カレンダーと月表示、「明日は出勤？」、IP クリーン度、公開 IP があります。

表示は **9 言語**に対応しています：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。

## インストール

**Apple Silicon Mac と macOS 14 以降**が必要です。

**Homebrew**:

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

更新は `brew upgrade --cask xstats` で行えます。

**直接ダウンロード**：[GitHub Releases](https://github.com/ysicing/xstats/releases) から DMG を入手し、開いて XStats を「アプリケーション」にドラッグして起動します。

アプリ自身がアップデートを確認し、ダウンロードとインストールの実行はユーザーが選べます。ソースからのビルドは[開発ガイド（中国語）](DEVELOPMENT.md)を参照してください。

## データとプライバシー

監視データ、ローカルの履歴、AI トークン統計は本機で処理し、XStats の更新サービスにはアップロードしません。次の機能は外部サービスに接続し、オフにするか必要なときだけ利用できます。

- **アップデートの確認**：現在のバージョンとインストール ID のハッシュを送り、更新情報を取得します。
- **AI 利用枠の照会**：ローカルの CLI ログインで提供元に照会します。代替ソースを設定した場合は、指定したサーバーに接続します。
- **費用の推定**：公開モデル単価と参考為替レートを必要に応じて取得し、セッションログやトークン統計は送信しません。
- **ネットワーク診断**：公開 IP、所在地、速度テスト、DNS、接続テスト、グローバルプローブは各サービスへ接続します。グローバルプローブの対象と結果は他の人が照会できる場合があります。

詳細は[プライバシーポリシー（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md)と[利用規約（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md)を参照してください。

## ビルドと貢献

Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/)、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。主なコマンド：

```bash
task test
task build BUMP=0 INSTALL=0
```

Issue と Pull Request を歓迎します。環境構築とリリース手順は [DEVELOPMENT.md（中国語）](DEVELOPMENT.md)、モジュールの境界と実装上の制約は [ARCHITECTURE.md（英語）](ARCHITECTURE.md)を参照してください。

## 変更履歴

最新の変更は [CHANGELOG.md（中国語）](CHANGELOG.md)を参照してください。

## 謝辞とライセンス

XStats は [OpenStats](https://github.com/gentpan/OpenStats) を基に開発しています。元のプロジェクトと、[ThirdPartyNotices.md](ThirdPartyNotices.md) に記載した他のオープンソースプロジェクトに感謝します。XStats は Apple や本文に記載した企業とは独立した第三者アプリです。

XStats の新規コードと変更部分には **AGPL-3.0-or-later** を適用します。[LICENSE](LICENSE) と [LICENSING.md（中国語）](LICENSING.md)を参照してください。OpenStats の元のコードには [MIT ライセンス](LICENSES/OpenStats-MIT.txt)が引き続き適用されます。
