<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**시스템 상태와 일상 도구를 Mac 메뉴 막대에 모으세요.**

CPU, 메모리, 네트워크, 온도를 한눈에 보고, 세부 화면에서 추이와 앱 사용량을 확인하세요.
AI 사용량, 달력, 팬 제어, 정리 도구는 필요할 때 켤 수 있습니다.

[![Release](https://img.shields.io/badge/version-0.14.5-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[최신 버전 다운로드](https://github.com/ysicing/xstats/releases) · [미리보기](#미리보기) · [주요 기능](#주요-기능) · [설치](#설치) · [변경 기록(중국어)](CHANGELOG.md)

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · **한국어**

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats 메뉴 막대 표시">

</div>

## 미리보기

메인 창에서 시스템 상태를 모아 볼 수 있으며, 취향에 따라 라이트와 다크 모드를 선택할 수 있습니다.

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 대시보드(다크)">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 대시보드(라이트)">
</p>

## 주요 기능

XStats는 Swift, AppKit, SwiftUI로 만든 무료 오픈소스 네이티브 앱입니다. XStats 계정 등록이 필요 없으며, 표시할 정보와 사용할 도구를 직접 선택할 수 있습니다.

### 원하는 메뉴 막대 표시 방식

- **개별 표시**: 자주 확인하는 지표마다 메뉴 막대 항목을 표시합니다.
- **통합 표시**: 여러 수치를 한 그룹에 모으고 펼쳐서 상태 개요를 확인합니다.
- **아이콘만**: XStats 아이콘 하나만 남기고 펼쳐서 선택한 항목을 확인합니다.

표시할 항목, 순서, 스타일을 바꿀 수 있습니다. 지표에 따라 텍스트, 아이콘, 링, 진행 막대, 기록 그래프를 선택하고, 필요 없는 항목은 끌 수 있습니다.

### 시스템 모니터링과 세부 정보

| 모듈 | 확인할 수 있는 정보 |
|---|---|
| **CPU** | 사용자 / 시스템 / 유휴 사용률, 코어별 부하 링, 코어 그룹 사용률, 평균 부하, 읽을 수 있는 주파수와 온도. macOS 열 상태가 높으면 경고 표시 |
| **GPU** | 그래픽 사용률, 코어 수 등 하드웨어 정보, 읽을 수 있는 온도와 소비 전력 |
| **메모리** | 메모리 압력, 앱 및 압축 메모리, 캐시, 스왑 공간, 스왑 인 / 아웃 속도 |
| **디스크** | 용량, 읽기/쓰기 속도, 앱별 I/O 순위, 읽을 수 있는 SMART 상태 정보 |
| **네트워크** | 업로드/다운로드 속도, 네트워크 인터페이스와 연결 개요 |
| **배터리와 Bluetooth** | 배터리 잔량, 전원, 건강 상태, 충전 사이클 수. 지원되는 Bluetooth 기기의 잔량은 배터리가 없는 Mac에서도 메뉴 막대에 표시 가능 |
| **온도와 팬** | 온도 센서 그룹, 팬 회전수, 읽을 수 있는 소비 전력 |
| **디스플레이** | 모델, 해상도, 스케일링 해상도, 주사율. 지원되는 외부 디스플레이의 밝기, 대비, 음량 조절 |

코어 유형은 시스템이 보고한 정보를 따릅니다. 실제 슈퍼 / 성능 / 효율 코어를 그룹으로 표시하며, 기종에 따라 두 그룹이나 세 그룹으로 고정하지 않습니다. ‘이 Mac’에서 모델, OS 버전, 가동 시간도 확인할 수 있습니다.

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU 사용률과 코어 세부 정보">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="메모리 구성과 압력">
</p>

**외부 디스플레이 제어**에는 모니터, 케이블, 연결 방식의 DDC/CI 지원이 필요합니다. 각 제어 항목을 따로 감지하며, 지원되지 않거나 일시적으로 읽을 수 없으면 상태를 표시합니다. 지원되는 항목에만 슬라이더를 제공합니다.

### AI 사용량과 구독 한도

메뉴 막대에서 Codex / Claude Code 사용량을 확인하고, 펼쳐서 통계와 한도 세부 정보를 볼 수 있습니다.

- **토큰 통계**: 오늘은 시간별, 최근 7일 / 30일은 일별로 표시합니다. 메인 창에서는 연간 활동 히트맵도 제공합니다.
- **구독 한도**: 사용 / 남은 비율을 전환하고 초기화 시각을 확인합니다. 소스가 제공하는 요금제, 유효기간, 사용 가능한 한도 초기화 횟수 등의 정보도 표시합니다.
- **추정 비용**: 모델의 공개 API 기본 단가로 계산하며 미국 달러 / 중국 위안 표시를 지원합니다. 구간별 추가 요금은 포함하지 않으며 구독 청구액을 의미하지 않습니다.
- **표시 설정**: 갱신 간격과 중국어 万 / 亿 또는 K / M / B 숫자 단위를 선택할 수 있습니다.

AI 사용량은 기본적으로 꺼져 있습니다. 로컬 통계는 Codex / Claude Code 세션 로그를 읽으며, 구독 한도 조회에는 해당 CLI 로그인이 필요합니다. Sub2API를 예비 소스로 직접 설정할 수도 있습니다.

### 필요할 때 켜는 일상 도구

- **팬 제어**: 동작 상태를 확인하고, 지원되는 기기에서 자동 / 수동 제어를 전환합니다.
- **잠자기 방지**: 시스템이나 화면을 깨어 있게 유지하며, 설정하면 덮개를 닫은 상태에서도 동작할 수 있습니다.
- **정리와 앱 제거**: 캐시, 프로젝트 빌드 산출물, 앱 관련 파일을 제거합니다. 실행 전에 미리 보고 확인하며, 휴지통으로 옮길 수도 있습니다.
- **시작 항목 관리**: 로그인 항목과 백그라운드 시작 항목을 확인하고 관리합니다.
- **네트워크 진단**: 속도 테스트, DNS 조회, 외부 연결 경로 검사, 공인 IP 위치 및 순도 확인, 연결 탐색을 필요할 때 실행합니다.
- **메뉴 막대 달력**: 음력, 중국 공휴일과 대체 근무일, 역서를 표시합니다. 권한을 허용하면 캘린더 일정과 미리 알림도 확인할 수 있습니다.
- **뽀모도로와 눈 휴식**: 집중 및 휴식 타이머, 여러 디스플레이의 휴식 화면을 제공하며 일시 정지, 건너뛰기, 미니 HUD 축소가 가능합니다.
- **프로세스 관리**: 켜면 모든 프로세스 표시, 검색, 정렬, 앱별 그룹화, 종료를 지원합니다.

정리, 프로세스, 달력, 뽀모도로, AI 사용량은 기본적으로 꺼져 있으며 필요할 때 켤 수 있습니다. 팬 제어와 덮개를 닫은 상태의 잠자기 방지 같은 권한이 필요한 작업에는 앱에서 보조 도구를 설치하고 권한을 허용해야 합니다.

<details>
<summary>다른 도구 스크린샷 보기</summary>

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="온도 및 팬 제어">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="잠자기 방지 설정">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="정리 미리보기">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="공인 IP 및 순도 확인">
</p>

</details>

### 데스크톱 위젯과 언어

위젯에는 시스템 개요, 뽀모도로, AI 한도, 달력과 월 달력, ‘내일 출근?’, IP 순도, 공인 IP가 있습니다.

인터페이스는 **9개 언어**를 지원합니다: 简体中文, 繁體中文, English, 日本語, 한국어, Deutsch, Español, Français, العربية.

## 설치

**Apple Silicon Mac과 macOS 14 이상**이 필요합니다.

**Homebrew**:

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

업데이트는 `brew upgrade --cask xstats`로 할 수 있습니다.

**직접 다운로드**: [GitHub Releases](https://github.com/ysicing/xstats/releases)에서 DMG를 받은 뒤, 열어서 XStats를 ‘응용 프로그램’으로 드래그하고 실행하세요.

앱이 업데이트를 확인하며, 새 버전의 다운로드와 설치 여부는 사용자가 선택합니다. 소스 빌드 방법은 [개발 안내(중국어)](DEVELOPMENT.md)를 참고하세요.

## 데이터와 개인정보

모니터링 데이터, 로컬 기록, AI 토큰 통계는 기기에서 처리하며 XStats 업데이트 서비스에 업로드하지 않습니다. 다음 기능은 외부 서비스에 연결하며, 끄거나 필요할 때 사용할 수 있습니다.

- **업데이트 확인**: 현재 버전과 설치 ID의 해시를 보내 업데이트 정보를 가져옵니다.
- **AI 한도 조회**: 로컬 CLI 로그인으로 제공자에 조회하며, 예비 소스를 설정하면 지정한 서버에 연결합니다.
- **비용 추정**: 공개 모델 단가와 참고 환율을 필요할 때 가져오며, 세션 로그나 토큰 통계는 보내지 않습니다.
- **네트워크 진단**: 공인 IP, 위치, 속도 테스트, DNS, 연결 탐색, 글로벌 프로브는 해당 서비스에 연결합니다. 글로벌 프로브의 대상과 결과는 다른 사람이 조회할 수 있습니다.

자세한 내용은 [개인정보 처리방침(영어)](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md)과 [서비스 약관(영어)](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md)을 확인하세요.

## 빌드와 기여

Xcode 26+, Go 1.25+, [Go Task](https://taskfile.dev/), [XcodeGen](https://github.com/yonaskolb/XcodeGen)이 필요합니다. 주요 명령:

```bash
task test
task build BUMP=0 INSTALL=0
```

Issue와 Pull Request를 환영합니다. 환경 설정과 릴리스 과정은 [DEVELOPMENT.md(중국어)](DEVELOPMENT.md), 모듈 경계와 구현 제약은 [ARCHITECTURE.md(영어)](ARCHITECTURE.md)을 참고하세요.

## 변경 기록

최신 변경 사항은 [CHANGELOG.md(중국어)](CHANGELOG.md)를 확인하세요.

## 감사와 라이선스

XStats는 [OpenStats](https://github.com/gentpan/OpenStats)를 기반으로 개발되었습니다. 원 프로젝트와 [ThirdPartyNotices.md](ThirdPartyNotices.md)에 명시한 다른 오픈 소스 프로젝트에 감사드립니다. XStats는 Apple 및 본문에 언급한 회사와 관계없는 독립적인 서드파티 앱입니다.

XStats의 새 코드와 수정 부분에는 **AGPL-3.0-or-later**가 적용됩니다. [LICENSE](LICENSE)와 [LICENSING.md(중국어)](LICENSING.md)를 확인하세요. 기존 OpenStats 코드는 [MIT 라이선스](LICENSES/OpenStats-MIT.txt)를 유지합니다.
