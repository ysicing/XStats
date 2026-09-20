#!/bin/bash
# 把 MaxMind 账号与 License Key 写到服务器的 /etc/openstats/maxmind.env，然后立刻同步一次 GeoLite2 数据库。
# 值在本机终端里输入（Key 不回显），只经 ssh 传到服务器，不进仓库、不进日志。
#
#   ./server/geoip/configure.sh
set -euo pipefail
HOST="${SITE_HOST:-debian@51.38.126.148}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

read -r -p "MaxMind Account ID: " ACCOUNT
read -r -s -p "MaxMind License Key: " LICENSE; echo
[ -n "$ACCOUNT" ] && [ -n "$LICENSE" ] || { echo "两项都要填" >&2; exit 1; }
case "$ACCOUNT$LICENSE" in *[!A-Za-z0-9_]*) echo "账号或 Key 含有意外字符" >&2; exit 1 ;; esac

# 通过标准输入写入，命令行参数里不出现 Key
printf 'MAXMIND_ACCOUNT_ID=%s\nMAXMIND_LICENSE_KEY=%s\n' "$ACCOUNT" "$LICENSE" \
  | "${SSH[@]}" 'sudo mkdir -p /etc/openstats && sudo tee /etc/openstats/maxmind.env >/dev/null && sudo chmod 600 /etc/openstats/maxmind.env && echo "已写入 /etc/openstats/maxmind.env"'
echo "开始第一次同步（三个库约 80 MB，需要一两分钟）…"
"${SSH[@]}" 'sudo systemctl start openstats-geoip.service && cat /var/www/getopenstats.com/geoip/manifest.json && echo'
