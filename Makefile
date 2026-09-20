PROJECT  := XStats.xcodeproj
SCHEME   := XStats
# 每次构建都会安装到 /Applications，默认用 Release
CONFIG   ?= Release
# ARCH=arm64 或 ARCH=x86_64 只编译一种芯片（发布脚本分别打 Apple 芯片版与 Intel 版）；不设时只编译本机芯片
ARCH     ?=
DERIVED  := build/DerivedData$(if $(ARCH),-$(ARCH))
APP      := $(DERIVED)/Build/Products/$(CONFIG)/XStats.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 与 QuotaBar 相同：钥匙串里有 Developer ID 证书就自动用它签名，否则退回 ad-hoc（仅限本机）。
# 也可以用 SIGN_ID="..." 显式指定。
SIGN_ID  ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')
TEAM_ID  := $(shell echo '$(SIGN_ID)' | sed -nE 's/.*\(([A-Z0-9]+)\)$$/\1/p')
ifneq ($(strip $(TEAM_ID)),)
# Release 加安全时间戳，公证要求如此，证书过期后签名依然有效
SIGN_FLAGS := CODE_SIGN_IDENTITY="$(SIGN_ID)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$(TEAM_ID) \
	$(if $(filter Release,$(CONFIG)),OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
endif

.PHONY: generate build compile run install release stop test snapshot open clean version bump-patch bump-minor bump-major

## 由 project.yml 生成 Xcode 工程
generate:
	xcodegen generate --quiet

## 编译 App（含辅助工具）并安装：卸载旧版、装上新版、启动，本机始终只有 /Applications 一份。
## 每次构建号加一（BUMP=0 不加）；INSTALL=0 只编译不安装（发布脚本使用）
build:
	@if [ "$(BUMP)" != "0" ]; then ./Scripts/version.sh build; fi
	@$(MAKE) --no-print-directory compile
	@if [ "$(INSTALL)" != "0" ]; then ./Scripts/install_local.sh $(APP); fi

compile: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(if $(ARCH),-destination 'generic/platform=macOS' ARCHS=$(ARCH) ONLY_ACTIVE_ARCH=NO,-destination 'platform=macOS') \
		-quiet $(SIGN_FLAGS) build

## 与 build 相同，保留旧名字
run install: build

## 发布：签名、公证、装订、打包 DMG，生成 Homebrew cask（见 Scripts/release.sh）
release:
	./Scripts/release.sh

stop:
	-pkill -x XStats

## 显示当前版本；发布前用 bump-patch（小改 0.2.0→0.2.1）或 bump-minor（大改 0.2.1→0.3.0）
version:
	@./Scripts/version.sh

bump-patch:
	@./Scripts/version.sh patch

bump-minor:
	@./Scripts/version.sh minor

bump-major:
	@./Scripts/version.sh major

## 单元测试
test:
	cd Packages/XStatsKit && swift test

## 用本机实时数据渲染各页面截图到 build/snapshots（使用已安装的应用，不重新构建）
snapshot:
	/Applications/XStats.app/Contents/MacOS/XStats --snapshot build/snapshots

open: generate
	open $(PROJECT)

clean:
	rm -rf build
