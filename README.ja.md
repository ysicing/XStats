<div align="center">

<img src="Assets/icon.png" alt="XStats" width="112" height="112">

# XStats

**Mac の状態をひと目で。CPU、GPU、メモリ、ネットワーク、温度をメニューバーで確認し、ファン制御、スリープ防止、キャッシュ削除、アプリのアンインストール、IP 評価も行えます。**

[![Release](https://img.shields.io/badge/version-0.6.1-6ee02b)](https://github.com/ysicing/xstats/releases)
[![Stars](https://img.shields.io/github/stars/ysicing/xstats?style=flat&color=f5c518)](https://github.com/ysicing/xstats/stargazers)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

XStats は、Mac の各 CPU コア、GPU、メモリ負荷、通信速度、ディスク、バッテリー、温度、ファンの状態を表示するメニューバーアプリです。
状態の確認に加えて、ファンの回転数調整、蓋を閉じた状態でのスリープ防止、キャッシュ削除、アプリと関連ファイルの削除、起動項目の管理ができます。
ネットワーク画面では、公開 IP が VPN、プロキシ、データセンター、不正利用などに関連付けられているかも確認できます。

テレメトリーはありません。XStats のアカウントは不要で、自分の WebDAV サーバーを使って設定を手動でバックアップ・復元できます。
公開 IP の照会、接続テスト、更新確認などのネットワーク機能は任意です。

[ダウンロード](https://github.com/ysicing/xstats/releases) · [変更履歴（中国語）](CHANGELOG.md) · [アーキテクチャ（英語）](ARCHITECTURE.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

</div>

## インストール

[GitHub Releases](https://github.com/ysicing/xstats/releases) で公開されているビルドを確認し、Mac に合わせて AppleSilicon または Intel を選んでください。
まだビルドが公開されていない場合は、下記の手順でソースからビルドできます。

macOS 14（Sonoma）以降が必要です。主に Apple Silicon で開発・検証しています。
Intel Mac では Apple Intelligence によるプロセス説明を利用できず、CPU コアの性能コア／効率コアへの分類や、一部の消費電力・周波数表示にも制限があります。
**アプリの表示言語は現在、簡体字中国語と英語です。日本語と韓国語に対応しているのは README です。**
表示言語はシステム設定に従い、アプリの設定から変更できます。

XStats の公式サイトはまだありません。自動更新と既存の GeoIP サービスは従来の構成を維持していますが、アカウントログインは WebDAV 同期に置き換えられました。
更新時のアプリ識別子・署名チェックは維持されているため、OpenStats 用のパッケージで XStats を置き換えることはできません。

## 更新情報

最新の変更と未リリースの内容は [CHANGELOG.md（中国語）](CHANGELOG.md) を参照してください。
現在の設定同期は WebDAV による手動操作です。GitHub、Google、Apple のログインと旧アカウントバックエンドは削除されています。

## 開発状況

<p align="center">
  <img src="Assets/readme/activity.svg" alt="過去 26 週間の日別コミット数（英語表記）" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#ysicing/xstats&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ysicing/xstats&type=Date&theme=dark">
      <img alt="GitHub スター数の推移" src="https://api.star-history.com/svg?repos=ysicing/xstats&type=Date" width="760">
    </picture>
  </a>
</p>

## スクリーンショット

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="ダッシュボード（ダーク）">
  <img src="Assets/readme/overview-light.png" width="49%" alt="ダッシュボード（ライト）">
</p>

スクリーンショット内の表示言語は中国語です。

## 主な機能

**メニューバー**

- 2 行テキスト、1 行テキスト、アイコン、リング、円グラフ、履歴バー、バッテリーバー、状態ドットの 8 種類から選択。項目ごとに異なるスタイルも指定できます。
- 通信速度は緑がアップロード、青がダウンロード。KB/s、MB/s、GB/s の単位を常に表示します。
- 等幅の数値で更新時の幅の変化を抑え、マウスを重ねると詳細な値を確認できます。

<p align="center"><img src="Assets/readme/menubar-dark.png" width="600" alt="メニューバー"></p>

**詳細ポップオーバー**

各項目をクリックすると詳細が開きます。表示するセクションは設定で選択でき、Esc で閉じられます。

- **CPU**：使用率、温度、過去 1／3／5 分の推移、コア別負荷とヒートマップ、周波数、平均負荷、アプリ別集計。
- **メモリ**：空き容量、メモリプレッシャー、圧縮メモリ、スワップの読み書き、アプリ別集計。
- **ネットワーク**：通信履歴、直近 60 回の接続テスト、インターフェース、Wi-Fi、VPN／プロキシ、ローカル・公開 IPv4／IPv6、国、ASN、IP 評価、DNS 管理、プロセス別通信量。
- **ディスク**：使用済み・削除可能・空き容量、読み書き速度と 60 秒間の推移、SSD の状態、アクセスの多いアプリ。
- **GPU・温度・ファン**：使用履歴、センサー群の温度、ファン回転数、制御モード。
- **バッテリー**：残量、使用可能時間・充電完了までの時間、アダプター出力、温度、24 時間の推移、消費電力、状態、充放電回数、接続中の Bluetooth 機器の残量。バッテリーのない Mac では Bluetooth 機器のみ表示します。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="32%" alt="CPU の詳細">
  <img src="Assets/readme/popover-disk-light.png" width="32%" alt="ディスクの詳細">
  <img src="Assets/readme/popover-memory-dark.png" width="32%" alt="メモリの詳細">
</p>

**IP 評価とネットワークテスト**

CleanIP.io によるスコア、F～A+ の評価、VPN・プロキシ・Tor・データセンター・不正利用などのフラグを表示します。
IPv4 と IPv6 を個別に確認し、結果は最長 7 日間ローカルにキャッシュします。IP の変更や手動更新時に再照会します。
速度テスト、各地域のノードへの接続確認、Globalping の公開プローブによる遅延・パケット損失の測定にも対応します。
Globalping の測定結果は公開されるため、自分で指定した対象に対して実行してください。速度テストには時間と通信量の上限があります。

<p align="center">
  <img src="Assets/readme/ip-purity-light.png" width="40%" alt="IP アドレスと評価（ライト）">
  <img src="Assets/readme/ip-purity-dark.png" width="40%" alt="IP アドレスと評価（ダーク）">
</p>

**メインウィンドウ**

サイドバーからダッシュボード、システム情報、履歴、各種指標、プロセス、起動項目、スリープ防止、クリーンアップ、アンインストール、設定を開けます。
ウィンドウはサイズ変更に対応し、ライト／ダークテーマを切り替えたり、システムに合わせたりできます。

**Apple Intelligence によるプロセス説明**

プロセスを右クリックすると、用途、負荷の妥当性、終了してよいかについて、システム内蔵モデルが説明します。
外部 AI サービスには接続しません。macOS 26 以降で Apple Intelligence を有効にする必要があります。説明は誤る場合があるため、終了前に内容を確認してください。

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="温度とファン">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="スリープ防止">
</p>

## ファン制御とスリープ防止

| モード | 動作 |
|---|---|
| 自動 | macOS に制御を戻します |
| 冷却 | 最低～最高回転数の範囲の 60% に固定します |
| 最大冷却 | 最高回転数で動作します |
| カスタム | スライダーで回転数を指定します |

カスタムモードでは CPU が安全温度（初期値 95°C）に達するとシステム制御へ戻ります。
XStats の終了時やクラッシュ時には自動制御へ戻り、蓋を閉じた状態での動作はバッテリー残量が指定値を下回ると解除されます。

これらの機能は SMAppService で登録する特権ヘルパーを使用します。初回はシステム設定のログイン項目で許可してください。
ヘルパーは署名を確認し、ファン制御、スリープ設定、DNS キャッシュ削除、メモリ解放などの固定操作のみを受け付けます。
任意のコマンドは実行しません。接続が切れた場合や、異常終了後の次回起動時にはファンとスリープ設定を復元します。

## クリーンアップ

- **対象**：アプリやブラウザーのキャッシュ、ログ、クラッシュレポート、Xcode・シミュレーター・npm のキャッシュ、Xcode アーカイブ、未完了ダウンロード、インストーラー、ゴミ箱。
- **削除前に確認**：種類別の容量とファイルを表示し、実行前に再確認します。通常、キャッシュとログは直接削除し、ダウンロードはゴミ箱へ移動します。すべてゴミ箱へ移動する設定もあります。
- **保護**：許可されたディレクトリのみを処理します。キーチェーン、パスワード管理、VPN、Cookie、履歴などを保護し、実行中アプリのキャッシュはスキップします。各項目を削除直前に再検証します。
- **記録**：操作ログは ~/Library/Logs/XStats/cleanup.log に保存します。
- **メンテナンス**：DNS キャッシュ削除とメモリ解放。ヘルパーがなければ管理者認証を求めます。

<p align="center"><img src="Assets/readme/cleaner-light.png" width="600" alt="クリーンアップ"></p>

## アンインストールと起動項目

- アプリを選択またはドラッグすると、関連するデータ、キャッシュ、設定、コンテナー、ログ、起動項目などを表示します。項目ごとに除外でき、確認後はアプリと一緒にゴミ箱へ移動します。システム／Apple のアプリは対象外で、実行中のアプリには終了を促します。
- ユーザーおよびシステムの LaunchAgents／LaunchDaemons とその状態を表示します。現在のユーザーの起動項目はファイルを削除せずに無効化・再有効化できます。それ以外は読み取り専用です。

<p align="center"><img src="Assets/readme/startup-items-light.png" width="600" alt="起動項目"></p>

## データとプライバシー

指標はローカルのカーネル、IOKit、SMC から取得し、設定はアプリの UserDefaults に保存します。テレメトリー送信はありません。
公開 IP は Cloudflare（失敗時は ipify）、IP 評価は cleanip.io に直接問い合わせます。接続テストは選択した対象へ ICMP ping を送り、更新確認は getopenstats.com のバージョン情報を取得します。
これらは設定で無効化できます。Apple Intelligence によるプロセス説明は端末内で行います。

### WebDAV 設定同期

1. 自分の WebDAV サーバーにディレクトリを作り、アプリの **Settings → Settings Sync**（英語 UI）を開きます。
2. 既存ディレクトリの HTTPS URL、ユーザー名、パスワードまたはアプリ専用パスワードを保存します。Basic 認証と有効な TLS 証明書が必要です。リダイレクト先には追従しないため、最終的なディレクトリ URL を指定してください。
3. **Upload Local Settings** で確認すると、xstats-settings.json を作成または上書きします。他の Mac の変更とはマージしません。
4. 別の Mac でも同じ接続情報を設定し、**Download and Apply** を選びます。検証後、**Apply and Overwrite** を押すと対象の設定を置き換えます。

同期は手動のみです。起動、スリープ解除、設定変更をきっかけに自動送信しません。
パスワードは各 Mac のキーチェーンに保存され、監視データ、履歴、WebDAV 接続情報はバックアップに含まれません。
JSON ファイル自体は追加暗号化しないため、非公開のディレクトリを使用してください。
初回はアップロードが必要です。1 MB を超えるファイル、不正な形式、未対応のバージョンは拒否し、ローカル設定を変更しません。
旧アカウントログインとバックエンドは削除済みです。iCloud 同期には対応していません。

## ビルドと実行

macOS 14 以降、**Xcode 26 以降**、[XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。
Command Line Tools だけでは SwiftUI のマクロプラグインが不足します。

~~~bash
brew install xcodegen
make run                  # Release ビルド、/Applications へインストール、起動
make install              # make run と同じ
make test                 # Swift パッケージのテスト
make open                 # Xcode プロジェクトを生成して開く
~~~

ビルドのみ行う場合は make build BUMP=0 INSTALL=0 を使います。通常のビルドではビルド番号が増え、インストール済みアプリを置き換えます。
ローカルの表示データを使ったスクリーンショットは次のコマンドで生成できます。

~~~bash
/Applications/XStats.app/Contents/MacOS/XStats --snapshot ./snapshots
~~~

パネルを開いたままにする場合は --show-panel を指定します。
CHANGELOG.md の変更後は python3 Scripts/sync_changelog.py を実行して、中国語・英語 README の更新情報と活動グラフを再生成します。

## 配布

SMC、他アプリのキャッシュ、特権ヘルパーを使うため、App Store のサンドボックス向けではありません。
ローカルビルドは Developer ID 証明書があれば使用し、なければ ad-hoc 署名を使います。ad-hoc ビルドはローカル検証用です。
一般配布には Developer ID 署名と Apple の公証が必要です。ヘルパーは自身と同じチームの署名を持つアプリだけを受け付けます。

~~~bash
make release                         # 署名、公証、ステープル、DMG と cask の生成
NOTARY_PROFILE=XStats make release   # 保存済みの公証プロファイルを指定
SKIP_NOTARIZE=1 make release          # 未公証のローカル検証用パッケージ
~~~

## 構成

- Packages/XStatsKit/Sources/SMC：SMC 通信、ファン制御、温度センサー。
- Packages/XStatsKit/Sources/Metrics：各種指標の収集と必要な項目だけを取得する MetricsHub。
- Packages/XStatsKit/Sources/Cleaner：クリーンアップ規則、安全検証、実行。
- Packages/XStatsKit/Sources/HelperShared：XPC プロトコルとメンテナンス操作。
- Packages/XStatsKit/Sources/WebDAVSync：WebDAV クライアントとキーチェーンのパスワード保存。
- Packages/XStatsKit/Sources/XStatsUI：画面、設定、ポップオーバー、メニューバー。
- Helper：特権ヘルパー。App：アプリのエントリーポイント。

詳細は [ARCHITECTURE.md（英語）](ARCHITECTURE.md) を参照してください。

## 謝辞

| プロジェクト | 作者 | ライセンス | 利用・参考にした内容 |
|---|---|---|---|
| [OpenStats](https://github.com/gentpan/OpenStats) | GiantAccel, LLC | MIT | XStats の元となったプロジェクト。オープンソースへの貢献に感謝します |
| [Stats](https://github.com/exelban/stats) | Serhiy Mytrovtsiy | MIT | SMC 通信、Apple Silicon のファン制御、メニューバー表示 |
| [Mole](https://github.com/tw93/Mole) | tw93 | GPL-3.0 | 清掃対象と保護対象の考え方。クリーンアップは独自の Swift 実装で、Mole のコードを含みません |
| [QuotaBar](https://github.com/gentpan/quotabar) | GiantAccel, LLC | MIT | README の構成、変更履歴の同期、活動グラフ |

詳細は [ThirdPartyNotices.md](ThirdPartyNotices.md) を参照してください。
XStats は独立した第三者アプリであり、Apple や本文中の他社による承認・支援を受けた製品ではありません。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
