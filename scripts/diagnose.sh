#!/usr/bin/env bash
# github-network-doctor: GitHub 全通道只读诊断
# 用法: bash diagnose.sh
# 只输出事实数据，不做判定；判定规则见 SKILL.md 第 1 步与 references/channels.md
# 兼容 Git Bash (Windows) / macOS / Linux

MAXT=8

hr() { printf '%s\n' "--------------------------------------------------------------------------"; }

dns_probe() {
  local domain="$1" ns ips
  if command -v nslookup >/dev/null 2>&1; then
    ns=$(nslookup "$domain" 2>/dev/null)
  elif command -v getent >/dev/null 2>&1; then
    ns=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}')
  fi
  # 提取全部类 IPv4 地址，滤除私网/回环/链路本地（nslookup 首行服务器地址），保留 0.0.0.0（污染信号）
  ips=$(printf '%s\n' "$ns" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)' \
        | awk '!seen[$0]++' | paste -sd ', ')
  # 单独捕获未指定地址 :: （投毒信号，勿与 fe80:: 等混淆）
  if printf '%s\n' "$ns" | grep -qE '(^|[[:space:]])::([[:space:]]|$)'; then
    ips="${ips:+$ips, }::"
  fi
  [ -z "$ips" ] && ips="NXDOMAIN/no-A-record"
  echo "$ips"
}

https_probe() {
  local r
  r=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}|%{remote_ip}" --max-time "$MAXT" "$1" 2>/dev/null)
  [ -z "$r" ] && r="000|n/a|"
  echo "$r"
}

ssh_probe() {
  local out
  out=$(ssh -o ConnectTimeout="$MAXT" -o BatchMode=yes -o StrictHostKeyChecking=no -T "git@$1" -p "$2" 2>&1)
  case "$out" in
    *"successfully authenticated"*) echo "OK (authenticated)";;
    *"Permission denied"*)          echo "REACHABLE (tcp ok, auth challenge)";;
    *"Connection refused"*)         echo "REFUSED";;
    *"Connection reset"*)           echo "RESET";;
    *)                              echo "TIMEOUT/BLOCKED";;
  esac
}

echo "== DNS =="
printf '%-32s %s\n' "domain" "resolved"
hr
for d in github.com api.github.com raw.githubusercontent.com codeload.github.com; do
  printf '%-32s %s\n' "$d" "$(dns_probe "$d")"
done

echo "== 代理环境 =="
hr
px="${http_proxy:-${HTTP_PROXY:-}}${https_proxy:+${https_proxy}}${HTTPS_PROXY:+ ${HTTPS_PROXY}}${ALL_PROXY:+ ${ALL_PROXY}}"
if [ -n "${http_proxy:-${HTTP_PROXY:-}}" ] || [ -n "${https_proxy:-${HTTPS_PROXY:-}}" ]; then
  echo "检测到代理: http_proxy=${http_proxy:-${HTTP_PROXY:-未设置}} https_proxy=${https_proxy:-${HTTPS_PROXY:-未设置}}"
  echo "注意: 下方 HTTPS 探测走代理，反映的是代理上游可达性，不等于系统直连；hosts 类修复是否有效以 hosts_repair.sh collect 的直连实测为准"
else
  echo "未检测到代理变量，HTTPS 探测反映系统直连路径"
fi

echo
echo "== HTTPS =="
printf '%-46s %-6s %-7s %s\n' "target" "code" "time_s" "remote_ip"
hr
for u in https://api.github.com https://github.com https://raw.githubusercontent.com/majiabin2020/github-accelerator/main/README.md https://codeload.github.com/majiabin2020/github-accelerator/tar.gz/refs/heads/main; do
  r=$(https_probe "$u")
  printf '%-46s %-6s %-7s %s\n' "$u" "$(echo "$r" | cut -d'|' -f1)" "$(echo "$r" | cut -d'|' -f2)" "$(echo "$r" | cut -d'|' -f3)"
done
# release 资产链路（github.com -> objects.githubusercontent.com），只取前 1KB 验证跳转链
r=$(curl -o /dev/null -sL -r 0-1023 -w "%{http_code}|%{time_total}|%{remote_ip}" --max-time 15 "https://github.com/cli/cli/releases/download/v2.93.0/gh_2.93.0_windows_amd64.zip" 2>/dev/null)
[ $? -ne 0 ] && r="000|timeout|"
printf '%-46s %-6s %-7s %s\n' "release-asset(objects)" "$(echo "$r" | cut -d'|' -f1)" "$(echo "$r" | cut -d'|' -f2)" "$(echo "$r" | cut -d'|' -f3)"

echo
echo "== SSH =="
printf '%-32s %s\n' "target" "result"
hr
printf '%-32s %s\n' "github.com:22"        "$(ssh_probe github.com 22)"
printf '%-32s %s\n' "ssh.github.com:443"   "$(ssh_probe ssh.github.com 443)"

echo
echo "== gh =="
hr
if command -v gh >/dev/null 2>&1; then
  acct=$(gh auth status 2>&1 | grep -i "account" | head -1 | sed 's/^ *//')
  [ -z "$acct" ] && acct="not logged in"
  proto=$(gh config get git_protocol 2>/dev/null)
  [ -z "$proto" ] && proto="(unset, default https)"
  printf '%-32s %s\n' "account" "$acct"
  printf '%-32s %s\n' "git_protocol" "$proto"
else
  echo "gh CLI not installed"
fi

echo
echo "参考判定: api 通=gh API 健康; 22 通=SSH 可用; 0.0.0.0 或非 GitHub 段 IP=DNS 污染; 000 且慢=阻断, 000 且快=DNS 层失败"
echo "注意: remote_ip=127.0.0.1 说明流量经本地代理(沙箱 shim 或用户代理); DNS 区(nslookup)绕过代理, HTTPS 区走代理, 两侧对照判读"
echo "GitHub 实时 IP 段: curl -s https://api.github.com/meta"
