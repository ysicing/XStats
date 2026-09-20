#!/bin/bash
# 在服务器上定时下载 MaxMind GeoLite2 数据库，放到官网 /geoip/ 下供 OpenStats 更新。
#
# 账号与 License Key 只放在 /etc/openstats/maxmind.env（root 所有，权限 600），
# 不进仓库、不进应用。文件内容：
#   MAXMIND_ACCOUNT_ID=你的账号
#   MAXMIND_LICENSE_KEY=你的 Key
#
# 每个库先下载 tar.gz 与官方 sha256 校验，解出 .mmdb 后原子替换，最后重写 manifest.json。
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/openstats/maxmind.env}"
OUT="${OUT:-/var/www/getopenstats.com/geoip}"
EDITIONS=(${EDITIONS:-GeoLite2-ASN GeoLite2-Country GeoLite2-City})

[ -r "$ENV_FILE" ] || { echo "缺少 $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${MAXMIND_ACCOUNT_ID:?}" "${MAXMIND_LICENSE_KEY:?}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

fetch() {
  # 凭据通过 curl 配置从标准输入传入，不出现在进程参数里
  printf 'user = "%s:%s"\n' "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" \
    | curl --config - -fsSL --retry 3 -o "$2" "https://download.maxmind.com/geoip/databases/$1/download?suffix=$3"
}

entries=()
for edition in "${EDITIONS[@]}"; do
  fetch "$edition" "$WORK/$edition.tar.gz" "tar.gz"
  fetch "$edition" "$WORK/$edition.tar.gz.sha256" "tar.gz.sha256"
  expected="$(cut -d' ' -f1 "$WORK/$edition.tar.gz.sha256")"
  actual="$(sha256sum "$WORK/$edition.tar.gz" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] || { echo "$edition 校验失败" >&2; exit 1; }

  tar -xzf "$WORK/$edition.tar.gz" -C "$WORK"
  folder="$(find "$WORK" -maxdepth 1 -type d -name "${edition}_*" | sort | tail -1)"
  build="${folder##*_}"   # 目录名形如 GeoLite2-ASN_20260912
  install -m 644 "$folder/$edition.mmdb" "$OUT/.$edition.mmdb.new"
  mv -f "$OUT/.$edition.mmdb.new" "$OUT/$edition.mmdb"

  sha="$(sha256sum "$OUT/$edition.mmdb" | cut -d' ' -f1)"
  size="$(stat -c %s "$OUT/$edition.mmdb")"
  entries+=("{\"edition\":\"$edition\",\"file\":\"$edition.mmdb\",\"build\":\"$build\",\"sha256\":\"$sha\",\"size\":$size}")
  echo "$edition $build $size 字节"
done

joined="$(IFS=,; echo "${entries[*]}")"
printf '{"generated":"%s","attribution":"This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com.","databases":[%s]}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$joined" > "$OUT/.manifest.json.new"
mv -f "$OUT/.manifest.json.new" "$OUT/manifest.json"
chmod 644 "$OUT/manifest.json"
echo "manifest.json 已更新"
