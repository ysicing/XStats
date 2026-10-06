#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/XStats Network Monitor.app"
mkdir -p "$APP/Contents"
python3 - "$APP" <<'PY'
import plistlib, pathlib, sys
info={'CFBundleIdentifier':'work.12306.xstats.networkmonitor','CFBundleExecutable':'XStats Network Monitor',
      'NetworkObservationProtocolVersion':2,'NetworkObservationControlMachService':'OLDTEAM.work.12306.xstats.network-observation.control'}
pathlib.Path(sys.argv[1],'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
bash "$ROOT/scripts/embed_network_agent.sh" "$APP" TESTTEAM01
python3 - "$APP" <<'PY'
import plistlib, pathlib, sys
app=pathlib.Path(sys.argv[1]); info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
agent=plistlib.loads((app/'Contents/Library/LaunchAgents/work.12306.xstats.networkmonitor.agent.plist').read_bytes())
assert info['NetworkObservationControlMachService']=='TESTTEAM01.work.12306.xstats.network-observation.control'
assert agent['Label']=='work.12306.xstats.networkmonitor.agent'
assert agent['BundleProgram']=='Contents/MacOS/XStats Network Monitor'
assert agent['ProgramArguments']==['XStats Network Monitor','--service']
assert agent['MachServices']=={info['NetworkObservationControlMachService']:True}
assert 'RunAtLoad' not in agent and 'KeepAlive' not in agent and 'Program' not in agent
PY
cp "$APP/Contents/Library/LaunchAgents/work.12306.xstats.networkmonitor.agent.plist" "$WORK/first.plist"
bash "$ROOT/scripts/embed_network_agent.sh" "$APP" TESTTEAM01
cmp "$WORK/first.plist" "$APP/Contents/Library/LaunchAgents/work.12306.xstats.networkmonitor.agent.plist"
python3 - "$APP" <<'PY'
import plistlib,pathlib,sys
file=pathlib.Path(sys.argv[1],'Contents/Info.plist');info=plistlib.loads(file.read_bytes())
info['NetworkObservationControlMachService']='$(TeamIdentifierPrefix)work.12306.xstats.network-observation.control'
file.write_bytes(plistlib.dumps(info))
PY
if env -u DEVELOPMENT_TEAM bash "$ROOT/scripts/embed_network_agent.sh" "$APP" > "$WORK/output" 2>&1; then
  echo '未展开的 Mach key 不应生成 LaunchAgent' >&2; exit 1
fi
grep -q 'Mach' "$WORK/output"
echo '按需网络 LaunchAgent 生成测试通过'
