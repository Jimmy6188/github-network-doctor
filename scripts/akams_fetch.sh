#!/usr/bin/env bash
# akams_fetch.sh — 经 akams 社区节点前缀代理下载 GitHub 资源，节点按实测优先级竞速
# 第三方中转：下载内容经节点服务器，须用户知情同意
# usage: bash akams_fetch.sh <原始URL> [-o 输出文件]
# 环境变量 AKAMS_NODES 可覆盖节点列表（空格分隔）
set -u

URL=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2;;
    -*) echo "unknown option: $1"; exit 1;;
    *)  URL="$1"; shift;;
  esac
done
[ -z "$URL" ] && { echo "usage: $0 <原始URL> [-o 输出文件]"; exit 1; }

NODES="${AKAMS_NODES:-github.tbap.top gh.dpik.top ghfile.geekertao.top}"
[ -z "$OUT" ] && OUT=$(basename "${URL%%\?*}")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for node in $NODES; do
  res=$(curl -sL --max-time 60 -w "%{http_code}|%{time_total}|%{size_download}" -o "$TMP/dl" "https://$node/$URL" 2>/dev/null)
  code=$(printf '%s' "$res" | cut -d'|' -f1)
  t=$(printf '%s' "$res" | cut -d'|' -f2)
  sz=$(printf '%s' "$res" | cut -d'|' -f3)
  if [ "$code" = "200" ] && [ "${sz:-0}" -gt 0 ] 2>/dev/null; then
    if head -c 15 "$TMP/dl" | grep -qiE '<!doctype|<html'; then
      echo "[$node] 200 但返回 HTML 页面，判失败，继续竞速"; continue
    fi
    mv "$TMP/dl" "$OUT"
    echo "[$node] 成功: $OUT (${sz}B, ${t}s)"
    exit 0
  else
    echo "[$node] 失败: code=$code time=$t"
  fi
done

echo "全部节点失败。可检查节点状态或改用 hosts 修复后直连。"
exit 1
