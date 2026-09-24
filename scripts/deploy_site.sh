#!/bin/bash
# 把 web/ 发布到 getopenstats.com（Caddy 静态站点，前面是 Cloudflare 橙云）。
#
# 静态资源在 Cloudflare 缓存一天，同一个 URL 换了内容，线上仍会拿到旧文件。
# 所以每个资源 URL 带 ?v=内容指纹：内容变了指纹就变，URL 跟着变。
# 最后按公网实际拿到的内容校验，而不是只看源站。
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${SITE_HOST:-debian@51.38.126.148}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
ROOT="${SITE_ROOT:-/var/www/getopenstats.com}"
DOMAIN="${SITE_DOMAIN:-getopenstats.com}"
SSH=(ssh -i "$KEY" -o BatchMode=yes)

# 官网里的更新日志由 CHANGELOG.md 生成，发布前先同步
python3 scripts/sync_changelog.py

# 先洗掉 ?v= 再算指纹，否则指纹会把自己算进去，内容没变也每次换值
STAMP="$( { cat web/styles.css web/replica.css web/app.js web/replica.js | /usr/bin/sed -E 's/\?v=[A-Za-z0-9]+//g'
           find web/assets -type f | sort | xargs cat; } | shasum -a 256 | cut -c1-8)"
echo "内容指纹 v=$STAMP"
/usr/bin/sed -i '' -E "s/\?v=[A-Za-z0-9]+/?v=$STAMP/g" web/index.html

# 目录归部署用户所有，Caddy 只需读取
"${SSH[@]}" "$HOST" "sudo mkdir -p $ROOT && sudo chown -R \$(id -un):\$(id -gn) $ROOT"
# geoip/ 由服务器上的定时任务生成，download/ 是 publish_release.sh 上传的安装包，都不在 web/ 里——
# 排除掉，否则 --delete 会把它们删了
rsync -az --delete --exclude /geoip/ --exclude /download/ -e "${SSH[*]}" web/ "$HOST:$ROOT/"
"${SSH[@]}" "$HOST" "sudo chmod -R a+rX $ROOT"
echo "已同步到 $HOST:$ROOT"

# 校验公网：Cloudflare 上拿到的文件大小与本地一致，首页引用的是新指纹
fail=0
for f in styles.css replica.css app.js replica.js; do
  want=$(stat -f%z "web/$f")
  got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 "https://$DOMAIN/$f?v=$STAMP" || true)
  if [ "$want" = "$got" ]; then
    printf "  ✅ %-12s %s B\n" "$f" "$got"
  else
    printf "  ❌ %-12s 线上 %s B ≠ 本地 %s B\n" "$f" "$got" "$want"
    fail=1
  fi
done
refs=$(curl -s --max-time 20 "https://$DOMAIN/" | grep -c "?v=$STAMP" || true)
if [ "${refs:-0}" -gt 0 ]; then
  printf "  ✅ 首页          引用 %s 处新指纹\n" "$refs"
else
  printf "  ❌ 首页仍在引用旧指纹，或域名尚未解析\n"
  fail=1
fi
exit $fail
