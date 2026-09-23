<div align="center">

<img src="Assets/icon.png" alt="XStats" width="112" height="112">

# XStats

**Mac の状態をひと目で。CPU、GPU、メモリ、ネットワーク、温度をメニューバーで確認し、ファン制御、スリープ防止、キャッシュ削除、アプリのアンインストール、IP 評価も行えます。**

[![Release](https://img.shields.io/badge/version-0.8.1-6ee02b)](https://github.com/ysicing/xstats/releases)
[![Stars](https://img.shields.io/github/stars/ysicing/xstats?style=flat&color=f5c518)](https://github.com/ysicing/xstats/stargazers)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

XStats は、Mac の各 CPU コア、GPU、メモリ負荷、通信速度、ディスク、バッテリー、温度、ファンの状態を表示するメニューバーアプリです。
状態の確認に加えて、ファンの回転数調整、蓋を閉じた状態でのスリープ防止、キャッシュ削除、アプリと関連ファイルの削除、起動項目の管理ができます。
ネットワーク画面では、公開 IP が VPN、プロキシ、データセンター、不正利用などに関連付けられているかも確認できます。Codex / Claude Code のローカルログからモデル別 Token 使用量も表示できます。

監視指標は Mac 内だけで処理され、アップロードされません。XStats のアカウントは不要で、自分の WebDAV サーバーを使って設定を手動でバックアップ・復元できます。更新確認では、インストール数の重複を除いてバージョン分布を集計するため、現在のバージョンとランダムなインストール ID の SHA-256 を送信します。元のランダム値はローカルの設定にのみ保存され、キーチェーンには保存されません。
公開 IP の照会、接続テスト、更新確認などのネットワーク機能は任意です。Codex 使用統計はローカル処理です。

[ダウンロード](https://github.com/ysicing/xstats/releases) · [変更履歴（中国語）](CHANGELOG.md) · [開発ガイド（中国語）](DEVELOPMENT.md)

[简体中文](README.md) · [English](README.en.md) · **日本語** · [한국어](README.ko.md)

</div>

## カレンダー
「設定 → メニューバー → カレンダー」で独立した日付表示を有効にできます。月・年の切り替え、
今日への移動、日付の詳細表示に対応します。西暦を常に表示し、旧暦、曜日、祝祭日、中国の振替出勤日、
二十四節気、干支、三伏、入梅・出梅は個別に切り替えられます。チベット暦とヒジュラ暦は初期設定では無効です。
設定は WebDAV バックアップに含まれます。

[Tyme4Swift 1.5.0](https://github.com/6tail/tyme4swift)（MIT、[第三者ライセンス](ThirdPartyNotices.md)）
でローカル計算します。閲覧範囲は 1900〜2100 年、チベット暦のデータ範囲は西暦 1951-01-08〜2051-02-11 です。
中国の法定休日データは現在 2026 年までで、範囲外はその旨を表示します。入梅・出梅は伝統的な暦の計算で、天気予報ではありません。

日付をクリックすると、宜忌、納音、沖煞、値神、時辰の吉凶、建除十二直、吉神・凶神、胎神、彭祖百忌、二十八宿の詳細を表示します。月表示に戻っても選択日は保持されます。


## インストール

[GitHub Releases](https://github.com/ysicing/xstats/releases) から Apple Silicon 版をダウンロードしてください。
まだビルドが公開されていない場合は、[開発ガイド（中国語）](DEVELOPMENT.md) を参照してソースからビルドできます。

Apple Silicon Mac と macOS 14（Sonoma）以降が必要です。
アプリは簡体字中国語、繁体字中国語、日本語、韓国語、英語、ドイツ語、スペイン語、フランス語、アラビア語に対応しています。
初期設定ではシステムの優先言語を自動検出します。設定の言語メニューで検索して切り替えられ、アラビア語では右から左のレイアウトを使用します。

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

**AI によるプロセス説明**

プロセスを右クリックすると、用途、負荷の妥当性、終了してよいかについて、システム内蔵モデルが説明します。
Apple Intelligence の端末内モデルのみを使用します。利用できない場合は理由を表示し、ほかのサービスには切り替えません。プロセスを終了する前に説明を確認してください。

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

- **対象**：アプリやブラウザーのキャッシュ、ログ、クラッシュレポート、Xcode・シミュレーター・npm・Yarn・pnpm・Bun・Go・Rust・uv のキャッシュ、Xcode アーカイブ、未完了ダウンロード、インストーラー、ゴミ箱。
- **削除前に確認**：種類別の容量とファイルを表示し、実行前に再確認します。開発ツールのキャッシュは内部フォルダーを直接削除せず、各ツールのコマンドでクリーンアップします。初回は未選択で、以後はこの Mac での選択状態を記憶します。ゴミ箱設定はフォルダー型キャッシュにのみ適用されます。
- **保護**：許可されたディレクトリのみを処理します。キーチェーン、パスワード管理、VPN、Cookie、履歴などを保護し、実行中アプリのキャッシュはスキップします。各項目を削除直前に再検証します。
- **記録**：操作ログは ~/Library/Logs/XStats/cleanup.log に保存します。
- **メンテナンス**：DNS キャッシュ削除とメモリ解放。ヘルパーがなければ管理者認証を求めます。

<p align="center"><img src="Assets/readme/cleaner-light.png" width="600" alt="クリーンアップ"></p>

## アンインストールと起動項目

- アプリを選択またはドラッグすると、関連するデータ、キャッシュ、設定、コンテナー、ログ、起動項目などを表示します。項目ごとに除外でき、確認後はアプリと一緒にゴミ箱へ移動します。システム／Apple のアプリは対象外で、実行中のアプリには終了を促します。
- ユーザーおよびシステムの LaunchAgents／LaunchDaemons とその状態を表示します。現在のユーザーの起動項目はファイルを削除せずに無効化・再有効化できます。それ以外は読み取り専用です。

<p align="center"><img src="Assets/readme/startup-items-light.png" width="600" alt="起動項目"></p>

## データとプライバシー

指標はローカルのカーネル、IOKit、SMC から取得し、設定はアプリの UserDefaults に保存します。監視指標、履歴、ハードウェアのシリアル番号、プロセス一覧はアップロードしません。
AI 使用統計は初期状態で無効です。有効にすると、ローカル Codex / Claude Code ログからモデル別 Token、キャッシュヒット率、日別推移を集計し、CLI のログイン情報を読み取り専用で確認して各サービスへ直接アクセスし、5 時間・週間の利用枠も取得します。既定は過去1年の活動ヒートマップ。日別・週別・累計の3表示はいずれも過去1年を表示します。SQLite に読取位置と統計を保存し、再起動後も差分を読み取ります。ログイン情報は XStats の設定や統計 DB に保存せず、セッションログは利用枠の問い合わせに送信しません。
両方のソースが有効で、いずれかに利用枠データがある場合、メニューバーの AI 項目に Codex と Claude を別々に表示します。データがないソースはダッシュで示し、リセット時刻はツールチップで確認できます。
ローカルの Codex または Claude Code ログインから利用枠を取得できない場合は、AI 使用統計の設定で各ソースに別々の Sub2API HTTPS アドレス、管理者メールアドレスとパスワード、アカウント ID を登録できます。それぞれの自動取得に失敗した場合だけ対応する設定を使用し、アカウントのプラットフォームも確認します。バックグラウンド照会は `force=false` で能動的な検査を行いません。管理者パスワードはソースごとにこの Mac のキーチェーンに保存し、接続設定は WebDAV バックアップに含めません。ログイン時には設定した Sub2API サーバーへ管理者情報を送信します。
Sub2API が Fable の数値を返さない場合、画面には利用枠データがないことを表示し、未取得の値を使用率 0% として扱いません。
公開 IP は Cloudflare（失敗時は ipify）、IP 評価は cleanip.io に直接問い合わせます。接続テストは選択した対象へ ICMP ping を送ります。更新確認は現在のバージョンとランダムなインストール ID の SHA-256 を送信してバージョン情報を取得します。中国地域では `x-stats.china.12306.work`、その他では `xstats-apps.12306.work` を優先し、失敗時のみもう一方へ順番にフォールバックして、最初の成功後は停止します。サーバーはこのハッシュ、現在のバージョン、初回／最終確認時刻、確認回数のみを保存し、シリアル番号を保存せず、リクエスト IP も永続化しません（1 分間のメモリ内レート制限にのみ使用します）。自動更新確認を無効にすると自動送信も停止します。
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

## 開発者向け

二次開発、ビルド、テスト、バージョン、署名・配布は
[DEVELOPMENT.md](DEVELOPMENT.md) を参照してください。詳しい構成は
[ARCHITECTURE.md（英語）](ARCHITECTURE.md) にあります。

## 謝辞

| プロジェクト | 作者 | ライセンス | 利用・参考にした内容 |
|---|---|---|---|
| [OpenStats](https://github.com/gentpan/OpenStats) | GiantAccel, LLC | MIT | XStats の元となったプロジェクト。オープンソースへの貢献に感謝します |
| [Stats](https://github.com/exelban/stats) | Serhiy Mytrovtsiy | MIT | SMC 通信、Apple Silicon のファン制御、メニューバー表示 |
| [Mole](https://github.com/tw93/Mole) | tw93 | GPL-3.0 | 清掃対象と保護対象の考え方。クリーンアップは独自の Swift 実装で、Mole のコードを含みません |
| [QuotaBar](https://github.com/gentpan/quotabar) | GiantAccel, LLC | MIT | README の構成、変更履歴の同期、活動グラフ |
| [AI Usage](https://github.com/burakgon/ai-usage-menubar) / [OpenUsage](https://github.com/robinebers/openusage) | Burak Gon / Robin Ebers | MIT | AI Provider 契約とテスト事例 |
| [usage-bar](https://github.com/methol-dev/usage-bar) | Krystian | BSD-2-Clause | Provider 状態と前回値保持の設計参考 |

詳細は [ThirdPartyNotices.md](ThirdPartyNotices.md) を参照してください。
XStats は独立した第三者アプリであり、Apple や本文中の他社による承認・支援を受けた製品ではありません。

## ライセンス

XStats の新規コードと変更部分には **AGPL-3.0-or-later** を適用します。[LICENSE](LICENSE) と [適用範囲・貢献時の要件（中国語）](LICENSING.md) を参照してください。

元の OpenStats のコードには [MIT ライセンスと著作権表示](LICENSES/OpenStats-MIT.txt) を引き続き適用します。その他の第三者ライセンスは [ThirdPartyNotices.md](ThirdPartyNotices.md) に記載しています。
