<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**Mac のメニューバーで使える、システム監視と日常のツール。**

CPU、メモリ、ネットワーク、温度をひと目で確認し、詳細を開いて推移やアプリの使用状況を見られます。AI 使用量、カレンダー、ファン制御などのツールは必要なときに有効にできます。

[![Release](https://img.shields.io/github/v/tag/ysicing/xstats?label=version&style=flat-square)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20%E3%82%B7%E3%83%AA%E3%82%B3%E3%83%B3-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Twitter](https://img.shields.io/badge/follow-YsiCing-red?style=flat-square&logo=Twitter)](https://twitter.com/YsiCing)

[最新版をダウンロード](https://github.com/ysicing/xstats/releases) · [機能](#機能) · [インストール](#インストール) · [データとプライバシー](#データとプライバシー) · [変更履歴（中国語）](CHANGELOG.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats のメニューバー表示">

</div>

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats ダッシュボード（ダーク）">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats ダッシュボード（ライト）">
</p>

## 機能

XStats は Swift、AppKit、SwiftUI で開発した、無料のオープンソースのネイティブアプリです。アカウント登録は不要です。

### メニューバーの表示

指標は**個別表示**、**集約モード**、**アイコンのみ**から選べます。表示する項目、並び順、スタイル（文字、アイコン、リング、進捗バー、履歴グラフ）を変更できます。

集約モードでは、各指標を一覧で確認し、個別の詳細を開けます。

<p align="center">
  <img src="Assets/readme/combined-overview-zh-Hans-light.png" width="360" alt="集約モードの概要、ライト表示">
  <img src="Assets/readme/combined-overview-zh-Hans-dark.png" width="360" alt="集約モードの概要、ダーク表示">
</p>

### 機能の有効化とメニューバー表示

設定 → 機能で、基本機能とオプション機能を別々に管理します。

- **基本モニタリング**：CPU、GPU、メモリ、ディスク、ネットワーク、温度とファン、バッテリーを個別にオン・オフできます。オフにすると収集、関連通知、新しい履歴の記録を停止し、既存の履歴は保持します。システムウィジェットは独立して更新します。
- **メニューバー表示**：基本モニタリング、AI 使用量、オーディオで「メニューバーに表示」を選ぶと、その機能も有効になります。チェックを外しても機能は有効なままです。AI 使用量とオーディオにも表示オプションがあります。
- **ディスプレイのパラメータ制御**：明るさ、コントラスト、音量の読み取りと調節を制御します。オフでもディスプレイ情報は表示でき、情報のみのメニューバー項目も別に設定できます。

<p align="center">
  <img src="Assets/readme/monitoring-features-zh-Hans-light.png" width="49%" alt="基本機能：有効化とメニューバー表示を別々に設定">
  <img src="Assets/readme/optional-features-zh-Hans-light.png" width="49%" alt="オプション機能：ツール、モジュール、集中と目の休憩、カレンダーを分類">
</p>

### システム監視

| モジュール | 内容 |
|---|---|
| **CPU** | ユーザー / システム / アイドルの使用率、コア別とコアグループの負荷、平均負荷、周波数と温度、熱負荷の警告 |
| **GPU** | グラフィックスの使用率、コア数、温度と消費電力 |
| **メモリ** | メモリプレッシャー、アプリ / 圧縮 / キャッシュの内訳、スワップ容量とスワップ速度 |
| **ディスク** | 容量、読み書きの速度、アプリ別 I/O ランキング、SMART 健全性 |
| **ネットワーク** | アップロード / ダウンロードの速度、ネットワークインターフェイス、接続の概要 |
| **バッテリーと Bluetooth** | 残量、電源、健全性、充放電回数、Bluetooth 機器の残量 |
| **温度とファン** | 温度センサー、ファン回転数、消費電力 |
| **ディスプレイ** | 解像度、スケーリング、リフレッシュレート。DDC/CI 対応の外部ディスプレイでは明るさ、コントラスト、音量を調節可能 |
| **システム情報** | Mac とシステムの識別情報。Apple Intelligence 横の詳細アイコンで機能の設定状態、デバイス上のモデルの利用可否と容量を確認 |

周波数、温度、消費電力などの値は、機種と macOS が提供する場合に表示されます。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU の使用率とコアの詳細">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="メモリ構成とプレッシャー">
</p>

### ネットワークモニター

**macOS 15 以降のオプション機能で、初期状態はオフです。** 監視中に観測した新しい接続をアプリ、プロセス、ドメイン、国・地域別に表示し、検索、アクティブ接続の絞り込み、一時停止と再開に対応します。

- **読み取り専用**：すべての通信を許可し、通信内容を読み取らず、接続履歴も保存しません。
- **必要なときだけ動作**：ページが表示され、一時停止していない間だけ読み取り、最大 512 件をメモリ内に保持します。観測開始前から存在するすべての接続を列挙するものではありません。
- **世界地図**：初回使用時に公開 IP 地理データベースをダウンロードし、その後はオフラインで検索します。位置は国・地域の代表点で、端末の正確な場所ではありません。

初回は、設定 → 機能 → オプション機能でネットワークモニターを有効にし、案内に沿ってコンポーネントをインストールし、macOS でシステム拡張とネットワークフィルターを許可します。インストールには管理者アカウントが必要です。「コンポーネントを管理」から個別に更新を確認したり、削除したりできます。

プレビュー版のコンポーネントを使用していた場合は、先に本体を更新し、コンポーネント管理で旧版を削除してください。macOS が再起動を求めた場合は完了後に再度有効にし、現在の更新元へ移行します。

<p align="center">
  <img src="Assets/readme/connections-zh-Hans-light.png" width="49%" alt="ネットワークモニターの接続概要、ライト表示、デモデータ">
  <img src="Assets/readme/connections-zh-Hans-dark.png" width="49%" alt="ネットワークモニターの接続概要、ダーク表示、デモデータ">
</p>

<p align="center">
  <img src="Assets/readme/component-install-zh-Hans-light.png" width="49%" alt="ネットワークコンポーネントの初回インストール画面、デモ状態">
  <img src="Assets/readme/component-management-zh-Hans-light.png" width="49%" alt="ネットワークコンポーネントの管理画面、デモのバージョン情報">
</p>

接続、アドレス、国・地域、コンポーネントのバージョン情報はデモデータです。

### AI 使用量

メニューバーで Codex / Claude Code の使用量を確認できます。

- **トークン統計**：今日は時間ごと、直近 7 日 / 30 日は日ごとに集計し、年間のアクティビティヒートマップも表示します。
- **サブスクリプション利用枠**：使用済み / 残りの割合、リセット時刻、プラン情報。Sub2API を代替ソースとして設定できます。
- **推定費用**：公開 API 基本単価から米ドル / 人民元で算出します。サブスクリプションの請求額ではありません。

ローカル統計は CLI のセッションログを読み込みます。利用枠の照会には対応する CLI へのログインが必要です。

### ツール

| ツール | 説明 |
|---|---|
| **ファン制御** | 対応機種で自動 / 手動制御を切り替え |
| **スリープ防止** | システムや画面を起動状態に保ち、蓋を閉じた状態での動作も設定可能 |
| **クリーンアップとアンインストール** | キャッシュ、ビルド成果物、アプリの残りファイルを確認してから削除 |
| **起動項目** | ログイン項目とバックグラウンドの起動項目を管理 |
| **ネットワーク診断** | 速度テスト、DNS 照会、外部接続経路の確認、公開 IP の所在地とクリーン度、接続テスト |
| **メニューバーカレンダー** | 旧暦、中国の祝日と振替出勤日、暦注、カレンダーの予定とリマインダー |
| **オーディオ** | システム音量と入出力機器の切り替え。macOS 14.4 以降ではアプリ別の音量と出力先を調節（本機で処理） |
| **集中と目の休憩** | ポモドーロ、複数画面の休憩表示、ミニ HUD。独立した目の休憩通知とローカル活動統計 |
| **プロセス管理** | 検索、並べ替え、アプリ別のグループ化、プロセスの終了 |

集中は開始・一時停止・終了で操作します。休憩後は自分で次のラウンドを開始するか、設定で自動開始を有効にできます。4ラウンドごとに長い休憩を挟みます。

休憩中の音は小雨、小川、風、ピンクノイズ、ホワイトノイズを本機で合成し、5秒間試聴できます。音源のダウンロードやマイクへのアクセスはありません。

「カスタム音声」で50 MBまでのローカル音声を読み込み、休憩中に繰り返し再生できます。元ファイルを移動してもアプリ内コピーを使えます。音声とファイル情報は設定バックアップに含めません。音をオフにすると試聴ボタンを非表示にします。

目の休憩リマインダーは初期状態でオフです。「集中と目の休憩」の設定で有効にできます。ポモドーロなしでも使え、近いラウンド間休憩とまとめます。ラウンド間休憩は集中後の休憩、目の休憩はいつでも始められる短い休憩で、時間は別々に設定します。目の休憩を始めると集中を一時停止し、再開は自分で選びます。集中と休憩の記録はこのMacに90日間保存され、統計から消去できます。設定バックアップに活動記録は含めません。休憩の音は5秒間試聴でき、音の変更や設定を閉じると停止します。

オプションのツールは、設定 → 機能 → オプション機能で必要に応じて有効にし、既存の設定は保持します。アプリのアンインストール機能は新規インストールでは初期状態がオフで、旧版からの更新では有効なままです。ファン制御や蓋を閉じた状態のスリープ防止などの特権操作には、アプリ内で補助ツールをインストールして許可を与える必要があります。

<details>
<summary>その他のスクリーンショット</summary>

ネットワーク接続、AI 使用量と利用枠、履歴、オーディオ、ディスプレイ、予定はデモデータです。基本的なシステム監視画面には本機の読み取り専用計測を含みます。利用できるハードウェア機能は機種によって異なります。

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="温度とファン制御">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="スリープ防止の設定">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="クリーンアップのプレビュー">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="公開 IP とクリーン度の確認">
</p>
<p align="center">
  <img src="Assets/readme/ai-usage-zh-Hans-light.png" width="49%" alt="AI 使用量と統計">
  <img src="Assets/readme/history-zh-Hans-dark.png" width="49%" alt="履歴の推移">
</p>
<p align="center">
  <img src="Assets/readme/audio-zh-Hans-light.png" width="49%" alt="音声とアプリ別ミキサー">
  <img src="Assets/readme/displays-zh-Hans-dark.png" width="49%" alt="外部ディスプレイの制御">
</p>
<p align="center">
  <img src="Assets/readme/calendar-zh-Hans-light.png" width="49%" alt="メニューバーカレンダー">
  <img src="Assets/readme/rest-zh-Hans-dark.png" width="49%" alt="集中と目の休憩：ポモドーロ、健康通知、今日の活動">
</p>

</details>

### 連携

- **デスクトップウィジェット**：システム概要、ポモドーロ、AI 利用枠、カレンダーと月表示、「明日は出勤？」、IP クリーン度、公開 IP。
- **表示言語**：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。
- **ディープリンク**：ランチャー、ショートカット、ターミナルから `xstats://` でよく使う画面を開けます。オフのモジュールは設定画面に移動し、自動では有効になりません。

```bash
open 'xstats://open/connections'   # ネットワークモニターを開く
open 'xstats://panel/cpu'          # CPU ポップオーバーを表示
```

全ルートと操作は[ディープリンク仕様](docs/DEVELOPMENT.md#xstats-深链)を参照してください。

## インストール

**Apple Silicon Mac と macOS 14 以降**が必要です。

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

または [GitHub Releases](https://github.com/ysicing/xstats/releases) から DMG を入手し、XStats を「アプリケーション」にドラッグします。アプリがアップデートを確認し、インストールするかどうかはユーザーが選べます。

## データとプライバシー

監視データ、ローカルの履歴、AI トークン統計は本機で処理し、XStats の更新サービスにはアップロードしません。次の機能は外部サービスに接続し、オフにするか必要なときだけ利用できます。

- **アップデートの確認**：本体と独立したネットワークコンポーネントが、それぞれのバージョンとインストール ID のハッシュを送り、更新情報を取得します。
- **AI 利用枠の照会**：ローカルの CLI ログインで提供元に照会します。代替ソースを設定した場合は、指定したサーバーに接続します。
- **費用の推定**：公開モデル単価と参考為替レートを必要に応じて取得し、セッションログやトークン統計は送信しません。
- **ネットワークモニター**：コンポーネントと公開地理データベースのダウンロード時に接続します。接続記録や接続先 IP はアップロードしません。
- **ネットワーク診断**：公開 IP、所在地、速度テスト、DNS、接続テスト、グローバルプローブは各サービスへ接続します。グローバルプローブの対象と結果は他の人が照会できる場合があります。

詳細は[プライバシーポリシー（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md)と[利用規約（英語）](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md)を参照してください。

## ビルドと貢献

Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/)、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。

```bash
task test
task build BUMP=0 INSTALL=0
```

Issue と Pull Request を歓迎します。環境構築とリリース手順は [DEVELOPMENT.md（中国語）](docs/DEVELOPMENT.md)、モジュールの境界と実装上の制約は [ARCHITECTURE.md（英語）](docs/ARCHITECTURE.md)を参照してください。

## 変更履歴

最新の変更は [CHANGELOG.md（中国語）](CHANGELOG.md)を参照してください。

## 謝辞とライセンス

XStats は [OpenStats](https://github.com/gentpan/OpenStats) を基に開発しています。元のプロジェクトと、[ThirdPartyNotices.md](ThirdPartyNotices.md) に記載した他のオープンソースプロジェクトに感謝します。XStats は Apple や本文に記載した企業とは独立した第三者アプリです。

XStats の新規コードと変更部分には **AGPL-3.0-or-later** を適用します。[LICENSE](LICENSE) と [LICENSING.md（中国語）](LICENSING.md)を参照してください。OpenStats の元のコードには [MIT ライセンス](LICENSES/OpenStats-MIT.txt)が引き続き適用されます。
