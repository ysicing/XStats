#!/bin/bash
# 把 GeoLite2 更新脚本与定时任务装到服务器（不包含 License Key）。
#   ./server/geoip/install.sh
set -euo pipefail
cd "$(dirname "$0")"
HOST="${SITE_HOST:-debian@51.38.126.148}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

scp -i "$KEY" -o BatchMode=yes openstats-geoip-update.sh openstats-geoip.service openstats-geoip.timer "$HOST:/tmp/"
"${SSH[@]}" 'set -e
  sudo install -m 755 /tmp/openstats-geoip-update.sh /usr/local/bin/openstats-geoip-update
  sudo install -m 644 /tmp/openstats-geoip.service /tmp/openstats-geoip.timer /etc/systemd/system/
  sudo install -d -m 755 /var/www/getopenstats.com/geoip
  # 只保证目录存在，保留已有权限，避免影响同机共用此目录的其他服务。
  sudo mkdir -p /etc/openstats
  sudo systemctl daemon-reload
  sudo systemctl enable --now openstats-geoip.timer
  rm -f /tmp/openstats-geoip-update.sh /tmp/openstats-geoip.service /tmp/openstats-geoip.timer
  systemctl list-timers openstats-geoip.timer --no-pager | head -3
  if sudo test -f /etc/openstats/maxmind.env; then echo "已找到 License Key 配置"; else echo "还没有 /etc/openstats/maxmind.env"; fi'
