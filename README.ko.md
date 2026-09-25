<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

macOS용 오픈 소스 메뉴 막대 시스템 모니터링 및 관리 앱입니다.

[![Release](https://img.shields.io/badge/version-0.9.2-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[다운로드](https://github.com/ysicing/xstats/releases) · [변경 기록(중국어)](CHANGELOG.md) · [개발 안내(중국어)](DEVELOPMENT.md)

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · **한국어**

</div>

XStats는 CPU, GPU, 메모리, 디스크, 네트워크, 배터리, 온도와 팬 상태를 메뉴 막대에 표시합니다. 항목을 열어 기록과 세부 정보를 확인하고, 팬 제어, 잠자기 방지, 캐시 정리, 앱 제거 기능도 사용할 수 있습니다.

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 다크 모드 대시보드">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 라이트 모드 대시보드">
</p>

## 주요 기능

- **시스템 모니터링**: 메뉴 막대 지표와 표시 방식을 선택하고 팝오버 또는 메인 창에서 추이, 프로세스, 하드웨어 정보를 확인합니다.
- **시스템 도구**: 팬 제어, 잠자기 방지, 캐시 정리, 앱 제거, 시작 항목 관리. 삭제 전에는 대상 확인 단계가 있습니다.
- **네트워크 도구**: 연결, DNS, 공인 IP를 확인하고 필요할 때 IP 평판과 연결 상태를 검사합니다.
- **선택 기능**: 독립적인 메뉴 막대 달력, Codex / Claude Code 로컬 세션의 토큰 통계와 구독 한도 조회.
- **데스크톱 위젯**: 시스템 개요, AI 구독 한도, 명절·황력 달력, 월간 달력, 내일 근무 여부, IP 신뢰도, 공인 IP. AI·IP·달력 데이터는 메인 앱의 로컬 캐시에서만 읽습니다.

## 설치

[GitHub Releases](https://github.com/ysicing/xstats/releases)에서 다운로드하세요. **Apple Silicon Mac과 macOS 14 이상**이 필요합니다. [소스에서 빌드](DEVELOPMENT.md)할 수도 있습니다.

중국어 간체·번체, 영어, 일본어, 한국어, 독일어, 스페인어, 프랑스어, 아랍어를 지원합니다. 새 버전을 찾더라도 설치 여부는 사용자가 결정합니다.

## 데이터와 개인정보

시스템 모니터링 데이터는 Mac에 남으며 XStats 계정은 필요하지 않습니다. AI 사용량 및 한도는 기본적으로 꺼져 있습니다. 켜면 구독 한도를 자동으로 감지합니다. 로컬 사용량은 기본으로 표시되며 별도로 끄면 세션 로그 검사가 중지됩니다. 한도 조회는 해당 CLI의 로그인 정보를 변경하지 않고 읽어 각 제공자에게 직접 요청합니다. 자신의 Sub2API 서버를 예비 한도 소스로 설정할 수 있습니다.

공인 IP 조회와 연결 테스트는 해당 기능을 사용할 때만 네트워크에 접속합니다. 업데이트 확인에서는 앱 버전과 무작위 설치 ID의 SHA-256을 보내며 서버는 요청 IP를 영구 저장하지 않습니다. WebDAV 동기화는 사용자가 직접 서버를 설정하고 수동으로 실행하며, 모니터링 기록이나 인증 정보가 아닌 설정만 전송합니다.

자세한 내용은 [개인정보 처리방침(영어)](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md)과 [서비스 약관(영어)](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md)을 확인하세요.

## 빌드와 기여

Xcode 26+, Go 1.25+, [Go Task](https://taskfile.dev/), [XcodeGen](https://github.com/yonaskolb/XcodeGen)이 필요합니다. 주요 명령:

```bash
task test
task build BUMP=0 INSTALL=0
```

Issue와 Pull Request를 환영합니다. 환경 설정과 릴리스 과정은 [DEVELOPMENT.md(중국어)](DEVELOPMENT.md), 구조는 [ARCHITECTURE.md(영어)](ARCHITECTURE.md)을 참고하세요.

## 변경 기록

최신 변경 사항은 [CHANGELOG.md(중국어)](CHANGELOG.md)를 확인하세요.

## 감사와 라이선스

XStats는 [OpenStats](https://github.com/gentpan/OpenStats)를 기반으로 개발되었습니다. 원 프로젝트와 [ThirdPartyNotices.md](ThirdPartyNotices.md)에 명시한 다른 오픈 소스 프로젝트에 감사드립니다. XStats는 Apple 및 본문에 언급한 회사와 관계없는 독립적인 서드파티 앱입니다.

XStats의 새 코드와 수정 부분에는 **AGPL-3.0-or-later**가 적용됩니다. [LICENSE](LICENSE)와 [LICENSING.md(중국어)](LICENSING.md)를 확인하세요. 기존 OpenStats 코드는 [MIT 라이선스](LICENSES/OpenStats-MIT.txt)를 유지합니다.
