#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -f scripts/release_network_component.sh ] || { echo '缺少独立组件发布脚本' >&2; exit 1; }

mkdir -p "$WORK/repo/scripts" "$WORK/bin" "$WORK/objects" "$WORK/sparkle"
for file in release_network_component.sh appcast.py sparkle_appcast.py; do
  cp "scripts/$file" "$WORK/repo/scripts/$file"
done
cat > "$WORK/repo/project.yml" <<'YAML'
NETWORK_EXTENSION_VERSION: "2.3.4"
NETWORK_EXTENSION_BUILD: "137"
MARKETING_VERSION: "9.9.9"
CURRENT_PROJECT_VERSION: "999"
YAML
cat > "$WORK/notes.json" <<'JSON'
{"version":"2.3.4","sourceNotes":["更新独立网络组件"],"translations":{"en":["Update the independent network component"]}}
JSON
cat > "$WORK/bin/security" <<'STUB'
#!/bin/sh
printf '1) testid "Developer ID Application: Fixture (TESTTEAM01)"\n'
STUB
cat > "$WORK/bin/task" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'task %s\n' "$*" >> "$COMPONENT_TEST_LOG"
python3 - <<'PY'
import os, pathlib, plistlib
app=pathlib.Path('build/DerivedData-network-arm64/Build/Products/Release/XStats Network Monitor.app')
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(app/'Contents/MacOS/XStats Network Monitor').write_text('fixture')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'work.12306.xstats.networkmonitor','CFBundleShortVersionString':'2.3.4','CFBundleVersion':'137','SUPublicEDKey':'j/I8zd8BXz4oPldnhocEySXTMmXPxKMyBRwoA4ewLIk=', 'NetworkObservationProtocolVersion':2, 'NetworkObservationControlMachService':'TESTTEAM01.work.12306.xstats.network-observation.control'}))
a=app/'Contents/Library/LaunchAgents'; a.mkdir(parents=True,exist_ok=True)
agent={'Label':'work.12306.xstats.networkmonitor.agent','BundleProgram':'Contents/MacOS/XStats Network Monitor','ProgramArguments':['XStats Network Monitor','--service'],'MachServices':{'TESTTEAM01.work.12306.xstats.network-observation.control':True}}
if os.getenv('COMPONENT_AGENT_INVALID')=='1': agent['KeepAlive']=True
(a/'work.12306.xstats.networkmonitor.agent.plist').write_bytes(plistlib.dumps(agent))
e=app/'Contents/Library/SystemExtensions/work.12306.xstats.app.networkextension.systemextension/Contents'
(e/'MacOS').mkdir(parents=True,exist_ok=True)
(e/'MacOS/work.12306.xstats.app.networkextension').write_text('fixture')
(e/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'work.12306.xstats.app.networkextension','CFBundleShortVersionString':'2.3.4','CFBundleVersion':'137'}))
s=app/'Contents/Frameworks/Sparkle.framework/Versions/Current'
for path in ('Sparkle','Autoupdate','Updater.app/Contents/MacOS/Updater','XPCServices/Installer.xpc/Contents/MacOS/Installer','XPCServices/Downloader.xpc/Contents/MacOS/Downloader'):
    p=s/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
PY
STUB
cat > "$WORK/bin/lipo" <<'STUB'
#!/bin/sh
echo arm64
STUB
cat > "$WORK/bin/codesign" <<'STUB'
#!/bin/sh
case "$*" in
  *--entitlements*) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.developer.system-extension.install</key><true/><key>com.apple.developer.networking.networkextension</key><array><string>content-filter-provider-systemextension</string></array><key>com.apple.security.application-groups</key><array><string>TESTTEAM01.work.12306.xstats.network-observation</string></array></dict></plist>' ;;
  *-dvv*) printf 'TeamIdentifier=TESTTEAM01\nTimestamp=fixture\nflags=runtime\n' >&2 ;;
esac
STUB
cat > "$WORK/bin/xcrun" <<'STUB'
#!/bin/sh
printf 'xcrun %s\n' "$*" >> "$COMPONENT_TEST_LOG"
STUB
cat > "$WORK/bin/spctl" <<'STUB'
#!/bin/sh
echo accepted
STUB
cat > "$WORK/bin/mc" <<'STUB'
#!/bin/bash
set -euo pipefail
name="${@: -1}"
name="${name##*/}"
printf 'upload %s\n' "$name" >> "$COMPONENT_TEST_LOG"
if [ "${COMPONENT_FAIL_ALIAS:-0}" = 1 ] && [ "$name" = XStats-Network-Monitor.zip ]; then exit 55; fi
cp "${@: -2:1}" "$COMPONENT_TEST_OBJECTS/$name"
STUB
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
name="${@: -1}"
name="${name##*/}"
name="${name%%\?*}"
printf 'verify %s\n' "$name" >> "$COMPONENT_TEST_LOG"
cat "$COMPONENT_TEST_OBJECTS/$name"
STUB
cat > "$WORK/sparkle/generate_keys" <<'STUB'
#!/bin/sh
echo 'j/I8zd8BXz4oPldnhocEySXTMmXPxKMyBRwoA4ewLIk='
STUB
cat > "$WORK/sparkle/sign_update" <<'STUB'
#!/bin/sh
case "$*" in *' -p '*) python3 -c 'import base64;print(base64.b64encode(b"s"*64).decode())';; esac
STUB
chmod +x "$WORK/bin/"* "$WORK/sparkle/"*
export PATH="$WORK/bin:$PATH" COMPONENT_TEST_LOG="$WORK/events" COMPONENT_TEST_OBJECTS="$WORK/objects" SPARKLE_TOOLS_DIR="$WORK/sparkle"
export SIGN_ID=testid XSTATS_COMPONENT_PROFILE=component XSTATS_NETWORK_PROFILE=extension
export NETWORK_RELEASE_NOTES="$WORK/notes.json"

expect_failure() {
  local expected="$1"
  shift
  if "$@" > "$WORK/stdout" 2> "$WORK/stderr"; then echo '错误地成功' >&2; exit 1; fi
  grep -q "$expected" "$WORK/stderr" || { cat "$WORK/stderr" >&2; exit 1; }
}

expect_failure 'Developer ID' env SIGN_ID=- bash "$WORK/repo/scripts/release_network_component.sh"
expect_failure XSTATS_COMPONENT_PROFILE env -u XSTATS_COMPONENT_PROFILE bash "$WORK/repo/scripts/release_network_component.sh"
expect_failure '公证' env SKIP_NOTARIZE=1 bash "$WORK/repo/scripts/release_network_component.sh" --publish
[ ! -e "$WORK/events" ] || { echo '前置条件失败不应构建或上传' >&2; exit 1; }

expect_failure 'LaunchAgent' env COMPONENT_AGENT_INVALID=1 bash "$WORK/repo/scripts/release_network_component.sh"
! grep -q '^xcrun ' "$WORK/events"
: > "$WORK/events"

bash "$WORK/repo/scripts/release_network_component.sh" > "$WORK/stdout"
[ ! -e "$WORK/objects/appcast.xml" ]
! grep -q '^upload ' "$WORK/events"
python3 - "$WORK/repo/dist/network-monitor/appcast.json" <<'PY'
import json,sys
feed=json.load(open(sys.argv[1]))
assert feed['version']=='2.3.4' and feed['build']=='137'
assert feed['minimumSystem']=='15.0'
assert feed['bundleIdentifier']=='work.12306.xstats.networkmonitor'
assert feed['networkExtension']=={'version':'2.3.4','build':'137'}
assert 'dmg' not in feed
PY

# 正常发布与失败重跑只操作独立前缀；alias 失败后不能更新 appcast。
: > "$WORK/events"
bash "$WORK/repo/scripts/release_network_component.sh" --publish > "$WORK/stdout"
grep -E '^(upload|verify) ' "$WORK/events" > "$WORK/order"
cat > "$WORK/expected" <<'ORDER'
upload XStats-Network-Monitor-2.3.4-137-AppleSilicon.zip
verify XStats-Network-Monitor-2.3.4-137-AppleSilicon.zip
upload XStats-Network-Monitor.zip
verify XStats-Network-Monitor.zip
upload appcast.xml
verify appcast.xml
ORDER
diff -u "$WORK/expected" "$WORK/order"
: > "$WORK/events"
if COMPONENT_FAIL_ALIAS=1 bash "$WORK/repo/scripts/release_network_component.sh" --publish > "$WORK/stdout" 2> "$WORK/stderr"; then
  echo 'alias 上传失败应中止发布' >&2; exit 1
fi
! grep -q '^upload appcast.xml' "$WORK/events"
[ ! -e "$WORK/repo/dist/appcast.json" ]
grep -q 'MARKETING_VERSION: "9.9.9"' "$WORK/repo/project.yml"
grep -q 'CURRENT_PROJECT_VERSION: "999"' "$WORK/repo/project.yml"
echo '独立网络组件发布脚本测试通过'
