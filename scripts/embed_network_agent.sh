#!/bin/bash
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
# 在 Xcode 的 Info.plist 展开后生成按需 LaunchAgent，再由外层应用签名封装。
set -euo pipefail
APP="${1:-${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}}"
TEAM="${2:-${DEVELOPMENT_TEAM:-}}"
python3 - "$APP" "$TEAM" <<'PY'
import pathlib, plistlib, re, sys
app=pathlib.Path(sys.argv[1]); info_file=app/'Contents/Info.plist'
info=plistlib.loads(info_file.read_bytes())
if info.get('CFBundleIdentifier')!='work.12306.xstats.networkmonitor':
    raise SystemExit('error: LaunchAgent 只能嵌入独立网络组件')
if info.get('NetworkObservationProtocolVersion')!=2:
    raise SystemExit('error: 网络组件协议版本必须为 2')
suffix='work.12306.xstats.network-observation.control'
team=sys.argv[2]
if team and not re.fullmatch(r'[A-Z0-9]+',team):
    raise SystemExit('error: 无效签名团队')
service=(team+'.'+suffix) if team else info.get('NetworkObservationControlMachService','')
if not isinstance(service,str) or not re.fullmatch(r'(?:[A-Z0-9]+\.)?'+re.escape(suffix),service):
    raise SystemExit('error: control Mach service 必须已展开签名团队')
if info.get('CFBundleExecutable')!='XStats Network Monitor':
    raise SystemExit('error: 网络组件可执行名称不正确')
if info.get('NetworkObservationControlMachService')!=service:
    info['NetworkObservationControlMachService']=service
    info_file.write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML,sort_keys=False))
label='work.12306.xstats.networkmonitor.agent'
agent={'Label':label,'BundleProgram':'Contents/MacOS/XStats Network Monitor',
       'ProgramArguments':['XStats Network Monitor','--service'],
       'MachServices':{service:True},'ProcessType':'Background'}
directory=app/'Contents/Library/LaunchAgents'; directory.mkdir(parents=True,exist_ok=True)
(directory/(label+'.plist')).write_bytes(plistlib.dumps(agent,fmt=plistlib.FMT_XML,sort_keys=False))
PY
